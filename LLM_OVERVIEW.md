# PNGine: LLM Overview

> A comprehensive guide for LLMs to understand PNGine's architecture, capabilities, and design decisions.

## Executive Summary

**PNGine** is a WebGPU bytecode engine that embeds interactive shader art directly in PNG files. The core innovation is **compile-time specialization**: analyzing what features a shader needs and generating the smallest possible payload + runtime.

**Unique value proposition**: Shader art that fits in a PNG file (~500 bytes for simple shaders, ~15 KB with embedded executor) and runs anywhere with WebGPU support (browsers, iOS, Android, desktop).

---

## The Problem

Traditional shader art faces three conflicting constraints:

1. **Portability** - Run everywhere (browsers, mobile, desktop)
2. **Minimal size** - Small enough to email or embed
3. **Self-contained** - No external runtime downloads

Existing approaches fail on at least one dimension:
- **Raw WGSL**: Browser-only, needs WebGPU setup
- **JavaScript bundles**: Large (~100 KB), not portable
- **Native apps**: Compile per platform, high friction

## PNGine's Solution

Embed a **tailored WASM executor** directly in each PNG. The compiler analyzes DSL features and includes only necessary code.

```
.pngine source → Compiler → PNG with embedded executor + bytecode
                              ↓
                    Runs on any WebGPU host
```

---

## Architecture Overview

### Three-Layer Design

```
┌─────────────────────────────────────────────────────────────┐
│ LAYER 1: DSL Compiler (Zig, build-time)                     │
│                                                              │
│  .pngine source → Lexer → Parser → Analyzer → Emitter       │
│                                       │                      │
│  Responsibilities:                    ├─ Detect plugins      │
│  • Parse high-level DSL               ├─ Resolve references  │
│  • Semantic analysis                  └─ Emit bytecode       │
│  • Complexity: unlimited (runs once)                         │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ LAYER 2: Payload (PNGB bytecode + embedded WASM)             │
│                                                              │
│  • Bytecode opcodes (resource creation, frame definitions)   │
│  • Data section (WGSL shader code, vertex data)              │
│  • Embedded WASM executor (tailored per payload)             │
│  • Compressed in PNG pNGb chunk via DEFLATE                  │
│  • Size: 500 bytes (simple) to 15 KB (with executor)         │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ LAYER 3: Host Runtime (Platform-specific)                    │
│                                                              │
│  1. Extract WASM executor and bytecode from PNG              │
│  2. Initialize WASM: parse header, emit resource commands    │
│  3. Per-frame: call WASM frame() function                    │
│  4. Read command buffer, execute WebGPU calls                │
│                                                              │
│  Hosts: Browser (WebGPU), iOS (Metal), Android (Vulkan)      │
└──────────────────────────────────────────────────────────────┘
```

### The Command Buffer Contract

Instead of calling WASM→JS for each GPU operation, the executor accumulates commands in a binary buffer. The host reads and executes all commands in one pass.

**Why this matters:**
- **Performance**: One WASM→JS transition per frame instead of hundreds
- **Portability**: Same binary format across all platforms
- **Simplicity**: Host just switches on opcode and executes

```
Command Buffer Layout:
┌─────────────────────────────────┐
│ Header (8 bytes)                │
│   total_len: u32                │
│   cmd_count: u16                │
│   flags: u16                    │
├─────────────────────────────────┤
│ Commands (variable)             │
│   [opcode: u8][args...]         │
│   e.g., CREATE_BUFFER:          │
│     [0x01][id:u16][size:u32]    │
│         [usage:u8]              │
└─────────────────────────────────┘
```

---

## Plugin System

The executor uses a plugin architecture for dead code elimination:

| Plugin | Feature | Size Cost |
|--------|---------|-----------|
| core | Bytecode parsing, command emission | 8 KB |
| render | Render pipelines, draw commands | +7 KB |
| compute | Compute pipelines, dispatch | +4 KB |
| wasm | Nested WASM execution | +15 KB |
| animation | Scene timeline switching | +3 KB |
| texture | Image/video loading | +5 KB |

**How it works:**
1. Analyzer detects which plugins are needed from DSL usage
2. Compiler selects smallest pre-built variant (8 combinations)
3. Unused code is eliminated at compile time

**Example detection:**
```
#renderPipeline found → plugins.render = true
#computePipeline found → plugins.compute = true
#wasmCall found → plugins.wasm = true
```

---

## DSL Syntax

PNGine uses a macro-based DSL that compiles to compact bytecode.

### Basic Example

```
#wgsl shader {
  value="
    @vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
      var pos = array<vec2f, 3>(vec2f(0, 0.5), vec2f(-0.5, -0.5), vec2f(0.5, -0.5));
      return vec4f(pos[i], 0, 1);
    }
    @fragment fn fs() -> @location(0) vec4f {
      return vec4f(1, 0, 0, 1);
    }
  "
}

#renderPipeline trianglePipeline {
  vertex={ module=$wgsl.shader entryPoint="vs" }
  fragment={ module=$wgsl.shader entryPoint="fs" }
}

#renderPass drawTriangle {
  pipeline=$renderPipeline.trianglePipeline
  draw=3
}

#frame main {
  perform=[drawTriangle]
}
```

### Resource Types

| Macro | Purpose |
|-------|---------|
| `#wgsl` | WGSL shader code |
| `#buffer` | GPU buffer (vertex, uniform, storage) |
| `#texture` | GPU texture |
| `#sampler` | Texture sampler |
| `#bindGroup` | Resource bindings |
| `#renderPipeline` | Render pipeline |
| `#computePipeline` | Compute pipeline |
| `#renderPass` | Render pass execution |
| `#computePass` | Compute pass execution |
| `#queue` | Queue operations (writeBuffer) |
| `#frame` | Frame definition |
| `#data` | Static data block |
| `#define` | Compile-time constant |

---

## Uniform System

### Built-in Uniforms (Auto-updated)

**`pngineInputs`** (16 bytes):
| Field | Type | Description |
|-------|------|-------------|
| `time` | f32 | Elapsed seconds since start |
| `width` | f32 | Canvas width in pixels |
| `height` | f32 | Canvas height in pixels |
| `aspect` | f32 | width / height |

**`sceneTimeInputs`** (12 bytes):
| Field | Type | Description |
|-------|------|-------------|
| `sceneTime` | f32 | Time within current scene |
| `sceneDuration` | f32 | Scene duration |
| `normalizedTime` | f32 | 0.0 to 1.0 progress |

### Usage Pattern

```
#buffer uniforms {
  size=16
  usage=[UNIFORM COPY_DST]
}

#queue writeInputs {
  writeBuffer={
    buffer=uniforms
    bufferOffset=0
    data=pngineInputs    // Built-in runtime data
  }
}

#frame main {
  perform=[writeInputs myRenderPass]
}
```

WGSL shader:
```wgsl
struct PngineInputs {
    time: f32,
    canvasWidth: f32,
    canvasHeight: f32,
    aspect: f32,
};

@group(0) @binding(0) var<uniform> inputs: PngineInputs;
```

### Custom Static Data

Compile-time constants via `#data`:
```
#data params {
  float32Array=[0.04 0.1 0.025]
}

#buffer paramBuffer {
  size=12
  usage=[UNIFORM COPY_DST]
  mappedAtCreation=params
}
```

---

## Ping-Pong Buffer Pattern

For compute simulations (boids, particles), use pool buffers:

```
#buffer particles {
  size=32768
  usage=[VERTEX STORAGE]
  pool=2                    // Creates particles_0, particles_1
}

#bindGroup simBindGroup {
  layout=auto
  entries=[
    { binding=0 buffer=$buffer.particles }  // Read
    { binding=1 buffer=$buffer.particles }  // Write
  ]
  bindGroupsPoolOffsets=[0 1]
}

#computePass update {
  pipeline=$computePipeline.sim
  bindGroups=[$bindGroup.simBindGroup]
  bindGroupsPoolOffsets=[0]    // Alternates each frame
  dispatch=[64 1 1]
}
```

Runtime alternation formula:
```
actual_id = base_id + (frame_counter + offset) % pool_size
```

---

## Data Generation Tiers

### Tier 1: Compile-Time (Static)

Data generated by Zig compiler, inlined in payload:
```
#buffer cubeVertices {
  fill=cubeMesh { size=1.0 format=pos_normal_uv }
}
```

**Best for:** Small static geometry (<2 KB)

### Tier 2: Compute Shader (GPU)

Data generated on GPU at first frame:
```wgsl
@compute @workgroup_size(64)
fn initParticles(@builtin(global_invocation_id) id: vec3u) {
    let i = id.x;
    particles[i].pos = vec2f(cos(f32(i)), sin(f32(i)));
}
```

**Best for:** Large procedural data (WGSL compresses better than raw data)

### Tier 3: Nested WASM (CPU)

Embedded WASM module for CPU computation:
```
#wasmCall physics {
  module={ url="physics.wasm" }
  func="simulate"
  args=[time]
  returns={ buffer=$buffer.particles offset=0 }
}
```

**Best for:** Existing physics engines (Rapier, box2d)

---

## Bytecode Format (PNGB)

```
Offset  Size  Description
──────  ────  ─────────────────────────
0       40    Header
               magic: "PNGB"
               version: u16
               flags: u16
               plugins: u8 bitfield
               section offsets...

40+     var   WASM Executor (if embedded)
        var   Bytecode Section
        var   String Table
        var   Data Section
        var   WGSL Import Table
        var   Uniform Binding Table
```

**Varint encoding** saves ~30% on typical payloads:
- 0-127: 1 byte
- 128-16383: 2 bytes
- 16384+: 4 bytes

---

## Cross-Platform Support

| Platform | GPU Backend | WASM Runtime |
|----------|-------------|--------------|
| Browser | Native WebGPU | Native WebAssembly |
| iOS | Metal via Dawn | wasm3 interpreter |
| Android | Vulkan via Dawn | wasm3 interpreter |
| Desktop | Native WebGPU | wasm3 interpreter |

Same payload works everywhere - host just implements command dispatcher.

---

## Size Metrics

### Typical Payload Breakdown

| Component | Bytes | % |
|-----------|-------|---|
| Header | 40 | 3% |
| Bytecode opcodes | 200 | 15% |
| String table | 50 | 4% |
| WGSL code | 800 | 60% |
| Vertex data | 200 | 15% |
| **Uncompressed** | ~1330 | |
| **After DEFLATE** | ~800 | 40% reduction |

### With Embedded Executor

| Configuration | Size |
|---------------|------|
| Simple triangle (core only) | ~1 KB |
| Rotating cube (core + render) | ~16 KB |
| Boids simulation (full) | ~20 KB |
| **vs Generic WebGPU setup** | ~100 KB |

---

## JavaScript API

```javascript
import { pngine, play, pause, stop, draw, destroy } from "pngine";

// Initialize from PNG with embedded bytecode
const p = await pngine("shader.png", {
  canvas: document.getElementById("canvas"),
  debug: true,
});

// Animation control
play(p);           // Start animation loop
pause(p);          // Pause (keeps time)
stop(p);           // Stop and reset
draw(p, { time: 2.5 });  // Manual render
destroy(p);        // Cleanup

// Properties
p.width;           // Canvas width
p.height;          // Canvas height
p.isPlaying;       // Animation state
p.time;            // Current time
```

---

## Key Design Decisions

### 1. Heavy Compiler, Light Executor

- **Compiler**: ~4000 lines, unlimited complexity (runs once)
- **Executor**: ~500 lines WASM + ~200 lines JS logic
- **Rationale**: Compiler runs on developer machine; executor runs on millions of devices

### 2. Command Buffer vs Direct Calls

- Batches GPU commands in binary buffer
- One WASM→JS transition per frame
- Platform-agnostic format
- **Trade-off**: Slight latency for cross-platform simplicity

### 3. Pre-built Variants vs JIT

- 8 pre-built executor variants
- Compiler selects smallest matching variant
- **Trade-off**: Some payloads slightly larger than optimal, but build time stays fast

### 4. Static Allocation Only

- All memory allocated at init
- No GC pauses during frame
- **Trade-off**: Must pre-size buffers, but frame rendering is deterministic

---

## Compiler Pipeline

```
Source (.pngine)
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│ Lexer (src/dsl/Lexer.zig)                                   │
│ • Sentinel-terminated input                                  │
│ • Labeled switch state machine                               │
│ • ~10M tokens/sec                                            │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│ Parser (src/dsl/Parser.zig)                                 │
│ • Iterative descent (explicit stack, no recursion)          │
│ • Compact AST with nodes + extra_data arrays                │
│ • Root node always at index 0                               │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│ Analyzer (src/dsl/Analyzer.zig)                             │
│ • 23 namespace-specific symbol tables                        │
│ • Reference resolution ($namespace.name)                     │
│ • Import cycle detection (iterative DFS)                     │
│ • Plugin detection from feature usage                        │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│ Emitter (src/dsl/Emitter.zig)                               │
│ • Assigns integer IDs to resources                           │
│ • Emits opcodes in dependency order                          │
│ • Builds data section (shaders, vertices)                    │
│ • Produces PNGB bytecode                                     │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
PNGB Bytecode (embedded in PNG)
```

---

## File Structure

```
src/
├── dsl/                  # DSL compiler
│   ├── Lexer.zig         # Tokenizer
│   ├── Parser.zig        # AST builder
│   ├── Analyzer.zig      # Semantic analysis
│   ├── Emitter.zig       # Bytecode generation
│   └── Compiler.zig      # High-level interface
├── bytecode/             # PNGB format
│   ├── format.zig        # Header + serialization
│   ├── opcodes.zig       # Opcode definitions
│   └── emitter.zig       # Low-level emission
├── executor/             # WASM runtime
│   ├── dispatcher.zig    # Opcode dispatch
│   └── command_buffer.zig
├── png/                  # PNG handling
│   ├── encoder.zig       # RGBA to PNG
│   └── embed.zig         # pNGb chunk
└── cli.zig               # CLI interface

npm/pngine/src/           # JavaScript runtime
├── index.js              # Public API
├── worker.js             # WebWorker entry
├── gpu.js                # Command dispatcher
└── anim.js               # Animation controls

examples/                 # Example .pngine files
├── simple_triangle.pngine
├── rotating_cube.pngine
└── boids.pngine
```

---

## CLI Usage

```bash
# Compile to bytecode
pngine compile shader.pngine -o output.pngb

# Create PNG with embedded bytecode (1x1 transparent)
pngine shader.pngine -o output.png

# Render actual frame via GPU
pngine shader.pngine --frame -s 512x512 -o output.png

# Validate bytecode
pngine check shader.pngine --verbose

# Embed bytecode in existing PNG
pngine embed image.png bytecode.pngb -o output.png

# Extract bytecode from PNG
pngine extract output.png -o extracted.pngb
```

---

## Testing

```bash
# All standalone tests (1,114 tests, parallel)
zig build test-standalone --summary all

# Individual modules
zig build test-dsl-frontend   # 75 tests - Lexer, Parser
zig build test-dsl-backend    # 119 tests - Analyzer
zig build test-bytecode       # 147 tests - Format, opcodes
zig build test-executor       # 114 tests - Dispatcher

# Full test suite (~5 min)
zig build test
```

---

## Summary

PNGine solves portable shader art distribution through:

1. **Compile-time specialization** - Analyze DSL, generate minimal executor
2. **Plugin system** - Include only needed code (8-45 KB)
3. **Command buffer abstraction** - Platform-agnostic GPU interface
4. **Embedded executor** - No external runtime needed
5. **Dense bytecode** - Varint encoding, DEFLATE compression

The result: Interactive shader art in a PNG file that runs everywhere.
