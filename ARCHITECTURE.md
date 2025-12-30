# PNGine Architecture Guide for LLMs

> **Document Type**: Reference (describes the machinery)
>
> **Audience**: LLMs and developers needing to understand PNGine's architecture
>
> **Prerequisites**: Basic understanding of WebGPU, WASM, and compilation pipelines

---

## Executive Summary

PNGine is a **WebGPU bytecode engine** that compiles a high-level DSL into compact
bytecode (PNGB) embedded in PNG files. The key architectural insight is the
separation of concerns:

- **Heavy Compiler (Zig)**: Runs once at build time, unlimited complexity
- **Minimal Payload (PNGB)**: Declarative bytecode + data, size-constrained
- **Tiny Executor (WASM)**: Interprets bytecode, emits GPU commands, ~15KB goal
- **Platform Viewer**: Executes GPU commands on native WebGPU/Dawn

```
                    COMPILE TIME                    RUNTIME
                        │                              │
   .pngine source ──► Compiler ──► PNG ──► Executor ──► GPU
       (DSL)           (Zig)     (PNGB)    (WASM)    (WebGPU)
                        │           │          │          │
                    Heavy work   Stored    Tiny work   Platform
                    (once)       (~15KB)   (per-frame)  native
```

---

## Core Concepts

### 1. The Payload (PNGB)

The **payload** is the compiled output embedded in a PNG file. It contains
everything needed to render except the executor and GPU driver.

**Key Properties:**
- **Declarative**: Describes WHAT to create, not HOW (no executable CPU code)
- **Self-contained**: All shaders, vertex data, textures embedded inline
- **Size-constrained**: Target <50KB for practical distribution
- **Platform-agnostic**: Same payload runs on any WebGPU-capable platform

**Structure (v0 format, 40-byte header):**
```
┌─────────────────────────────────────────────────────────────────┐
│ Header (40 bytes)                                               │
│   magic: "PNGB" (4 bytes)                                       │
│   version: u16 (0)                                              │
│   flags: u16 (has_embedded_executor, has_animation_table)       │
│   plugins: u8 (PluginSet bitfield)                              │
│   reserved: [3]u8                                               │
│   executor_offset: u32                                          │
│   executor_length: u32                                          │
│   string_table_offset: u32                                      │
│   data_section_offset: u32                                      │
│   wgsl_table_offset: u32                                        │
│   uniform_table_offset: u32                                     │
│   animation_table_offset: u32                                   │
├─────────────────────────────────────────────────────────────────┤
│ Executor WASM (if embedded)                                     │
├─────────────────────────────────────────────────────────────────┤
│ Bytecode Section                                                │
│   - Resource creation opcodes (CREATE_BUFFER, CREATE_SHADER)    │
│   - Frame definitions (DEFINE_FRAME, EXEC_PASS)                 │
│   - Pass definitions (BEGIN_RENDER_PASS, DRAW, END_PASS)        │
├─────────────────────────────────────────────────────────────────┤
│ String Table                                                    │
│   - Interned strings (entry point names, frame names)           │
├─────────────────────────────────────────────────────────────────┤
│ Data Section                                                    │
│   - WGSL shader code (as raw strings)                           │
│   - Vertex data (float arrays)                                  │
│   - Pipeline descriptors (JSON-encoded)                         │
│   - Embedded WASM modules (for #wasmCall)                       │
├─────────────────────────────────────────────────────────────────┤
│ WGSL Table                                                      │
│   - Maps wgsl_id → data_id + dependency list                    │
├─────────────────────────────────────────────────────────────────┤
│ Uniform Table                                                   │
│   - Runtime-settable uniform bindings                           │
├─────────────────────────────────────────────────────────────────┤
│ Animation Table                                                 │
│   - Scene definitions, timeline, durations                      │
└─────────────────────────────────────────────────────────────────┘
```

**Source files:**
- `src/bytecode/format.zig` - Header and serialization (1,400 lines)
- `src/bytecode/opcodes.zig` - PNGB opcode definitions
- `src/bytecode/data_section.zig` - Data blob storage
- `src/bytecode/string_table.zig` - Interned strings

### 2. The Executor

The **executor** is a WASM module that interprets PNGB bytecode and emits GPU
commands. It can be:
- **Shared**: External `pngine.wasm` loaded at runtime (~57KB current)
- **Embedded**: Tailored executor in payload (~15KB goal)

**Key Properties:**
- **Statically allocated**: No malloc after init (WASM linear memory)
- **Plugin-based**: Only includes needed features
- **Command buffer output**: Platform-agnostic GPU command format

**Executor Interface (WASM exports):**
```zig
/// Initialize executor with bytecode. Emits resource creation commands.
export fn init() void;

/// Render a frame. Emits per-frame draw commands.
export fn frame(time: f32, width: u32, height: u32) void;

/// Get pointer to command buffer output.
export fn getCommandPtr() [*]const u8;

/// Get command buffer length.
export fn getCommandLen() u32;
```

**Source files:**
- `src/wasm_entry.zig` - WASM entry points (1,100 lines)
- `src/executor/dispatcher.zig` - Bytecode interpretation
- `src/executor/command_buffer.zig` - Command buffer format

### 3. The Plugin Architecture

Executors are tailored per-payload based on DSL analysis. Only needed code is
included, reducing WASM size.

**Plugins:**
| Plugin | When Included | Features |
|--------|---------------|----------|
| `core` | Always | Bytecode parsing, buffer creation, command emission |
| `render` | #renderPipeline, #renderPass | Render pipelines, draw commands |
| `compute` | #computePipeline, #computePass | Compute pipelines, dispatch |
| `wasm` | #wasmCall | Nested WASM execution |
| `animation` | #animation | Scene timeline, transitions |
| `texture` | #texture with external source | Image/video texture loading |

**PluginSet bitfield (1 byte):**
```zig
pub const PluginSet = packed struct(u8) {
    core: bool = true,       // bit 0 - always true
    render: bool = false,    // bit 1
    compute: bool = false,   // bit 2
    wasm: bool = false,      // bit 3
    animation: bool = false, // bit 4
    texture: bool = false,   // bit 5
    reserved: u2 = 0,        // bits 6-7
};
```

**Source files:**
- `src/types/plugins.zig` - PluginSet definition
- `src/executor/plugins/*.zig` - Plugin implementations

### 4. The Heavy Compiler

The **compiler** transforms DSL source into PNGB bytecode. It runs once at build
time with unlimited complexity:

**Compilation Pipeline:**
```
.pngine source
    │
    ▼ Lexer (Token.zig)
  tokens[]
    │
    ▼ Parser (Parser.zig)
   AST (nodes + extra_data)
    │
    ▼ Analyzer (Analyzer.zig)
   Symbol tables + validated AST + PluginSet
    │
    ▼ Emitter (Emitter.zig)
   PNGB bytecode
    │
    ▼ PNG embed (embed.zig)
   PNG with pNGb chunk
```

**Compiler Responsibilities:**
- Parse and validate DSL syntax
- Resolve references (`$buffer.name`, `$wgsl.shader`)
- Detect import cycles in WGSL modules
- Generate vertex data from shape generators (`cube=`, `plane=`)
- Determine required plugins
- Embed executor WASM (if requested)
- Compress payload with DEFLATE

**Source files:**
- `src/dsl/Compiler.zig` - High-level compile() interface
- `src/dsl/Token.zig` - Token definitions (24 macro keywords)
- `src/dsl/Lexer.zig` - Labeled switch state machine tokenizer
- `src/dsl/Parser.zig` - Iterative descent parser (no recursion)
- `src/dsl/Analyzer.zig` - Semantic analysis, plugin detection
- `src/dsl/Emitter.zig` - Bytecode emission

### 5. Minimal Viewer Runtimes

**Viewers** execute command buffers on native GPU APIs. They need minimal code
because the executor handles interpretation.

**Browser Viewer (npm/pngine):**
```
PNG file ─► extract.js ─► loader.js ─► worker.js ─► gpu.js ─► WebGPU
              │              │            │           │
           Extract       Load WASM     Run WASM   Execute
           bytecode      executor      per-frame  commands
```

**Key JS files:**
- `npm/pngine/src/init.js` - Main thread initialization (250 lines)
- `npm/pngine/src/worker.js` - WebWorker entry point (306 lines)
- `npm/pngine/src/gpu.js` - Command dispatcher (697 lines)
- `npm/pngine/src/loader.js` - Embedded executor support (254 lines)

**Native Viewers (future):**
- Desktop: Zig + wasm3 + Dawn
- iOS: Swift + wasm3 + Metal (via Dawn)
- Android: Kotlin + wasm3 + Vulkan (via Dawn)

---

## The Two Opcode Sets

**Critical insight**: PNGine has TWO separate opcode enumerations that serve
different purposes. Confusing them causes bugs.

### PNGB Bytecode Opcodes

**Purpose**: Stored in compiled `.pngb` files, interpreted by executor

**Location**: `src/types/opcodes.zig`

**Categories:**
```
0x00-0x0F: Resource Creation
  0x01 create_buffer
  0x04 create_shader_module
  0x08 create_render_pipeline
  0x0A create_bind_group

0x10-0x1F: Pass Operations
  0x10 begin_render_pass
  0x16 draw
  0x18 dispatch
  0x19 end_pass

0x20-0x2F: Queue Operations
  0x20 write_buffer
  0x2A write_time_uniform

0x30-0x3F: Frame Control
  0x30 define_frame
  0x32 exec_pass
  0x35 exec_pass_once

0x40-0x4F: Pool Operations
  0x41 set_vertex_buffer_pool
  0x42 set_bind_group_pool
```

### Command Buffer Opcodes

**Purpose**: Output by executor, consumed by platform viewer (gpu.js)

**Location**: `src/executor/command_buffer.zig`

**Categories:**
```
0x01-0x0F: Resource Creation
  0x01 create_buffer
  0x04 create_shader
  0x05 create_render_pipeline
  0x07 create_bind_group

0x10-0x1F: Pass Operations
  0x10 begin_render_pass
  0x15 draw
  0x17 end_pass
  0x18 dispatch

0x20-0x2F: Queue Operations
  0x20 write_buffer
  0x21 write_time_uniform

0x30-0x3F: WASM Operations
  0x30 init_wasm_module
  0x31 call_wasm_func

0xF0: submit
0xFF: end
```

### How They Relate

```
           PNGB Opcodes                     Command Buffer Opcodes
         (stored in file)                   (output by executor)
               │                                    │
               ▼                                    ▼
┌─────────────────────────┐            ┌─────────────────────────┐
│ Compiler emits PNGB     │            │ Executor emits commands │
│ opcodes into bytecode   │ ─────────► │ into command buffer     │
│                         │  (runtime) │                         │
│ 0x10 begin_render_pass  │            │ 0x10 begin_render_pass  │
│ 0x16 draw               │            │ 0x15 draw               │
│ 0x24 submit             │            │ 0xF0 submit             │
└─────────────────────────┘            └─────────────────────────┘
                                                   │
                                                   ▼
                                       ┌─────────────────────────┐
                                       │ gpu.js executes commands│
                                       │ via WebGPU API          │
                                       └─────────────────────────┘
```

**Key differences:**
- PNGB opcodes use varint encoding, command buffer uses fixed-size
- Some opcodes have different numbers (draw: 0x16 vs 0x15)
- Command buffer includes WASM-specific opcodes (0x30-0x31)
- Command buffer has explicit `end` marker (0xFF)

---

## DSL to WebGPU Mapping

The DSL provides 1:1 mapping to WebGPU concepts with ergonomic syntax:

### Resource Macros

| DSL Macro | WebGPU Concept | Example |
|-----------|----------------|---------|
| `#buffer` | `GPUBuffer` | `#buffer vb { size=1024 usage=[VERTEX] }` |
| `#texture` | `GPUTexture` | `#texture depth { format=depth24plus }` |
| `#sampler` | `GPUSampler` | `#sampler linear { magFilter=linear }` |
| `#wgsl` / `#shaderModule` | `GPUShaderModule` | `#shaderModule code { code="..." }` |
| `#bindGroup` | `GPUBindGroup` | `#bindGroup bg { entries=[...] }` |
| `#renderPipeline` | `GPURenderPipeline` | `#renderPipeline pipe { vertex={...} }` |
| `#computePipeline` | `GPUComputePipeline` | `#computePipeline sim { compute={...} }` |

### Pass Macros

| DSL Macro | WebGPU Concept | Key Properties |
|-----------|----------------|----------------|
| `#renderPass` | `GPURenderPassEncoder` | `colorAttachments`, `pipeline`, `draw` |
| `#computePass` | `GPUComputePassEncoder` | `pipeline`, `dispatch` |
| `#queue` | `GPUQueue.writeBuffer()` | `writeBuffer={buffer, data}` |

### Frame Macro

| DSL Macro | Purpose | Example |
|-----------|---------|---------|
| `#frame` | Define execution order | `#frame main { perform=[pass1 pass2] }` |

### Execution Model

```
#frame main {
  before=[setupQueue]        // Run once before first frame
  init=[initCompute]         // Run once (exec_pass_once)
  perform=[computePass renderPass]  // Run every frame
}
```

Translates to:
```
Per-frame loop:
  1. Execute init passes (only first frame)
  2. Execute perform passes in order
  3. Submit command encoder
```

### Built-in Data Sources

| Identifier | Size | Contents |
|------------|------|----------|
| `pngineInputs` | 16 bytes | time(f32), width(f32), height(f32), aspect(f32) |
| `sceneTimeInputs` | 12 bytes | sceneTime, sceneDuration, normalizedTime |
| `contextCurrentTexture` | - | Canvas texture for render pass |
| `canvas.width` / `canvas.height` | u32 | Canvas dimensions |

---

## Data Flow: Complete Example

**Simple Triangle (examples/simple_triangle.pngine):**

```
#renderPipeline pipeline {
  layout=auto
  vertex={ entryPoint=vertexMain module=code }
  fragment={ entryPoint=fragMain module=code targets=[{format=preferredCanvasFormat}] }
}

#renderPass drawTriangle {
  colorAttachments=[{ view=contextCurrentTexture clearValue=[0,0,0,0] loadOp=clear storeOp=store }]
  pipeline=pipeline
  draw=3
}

#frame simpleTriangle { perform=[drawTriangle] }

#shaderModule code {
  code="@vertex fn vertexMain(...) -> @builtin(position) vec4f { ... }
        @fragment fn fragMain() -> @location(0) vec4f { ... }"
}
```

**Compilation:**
```
1. Lexer: 47 tokens
2. Parser: AST with 4 macro nodes
3. Analyzer: Symbol tables, validates references, detects [render] plugin
4. Emitter:
   - create_shader_module(0, data_id=0)
   - create_render_pipeline(0, desc_data_id=1)
   - define_frame(0, name_id=0)
   - exec_pass(0)  // points to pass definition
   - end_frame
5. Output: ~500 bytes PNGB
```

**Runtime (browser):**
```
1. Extract pNGb chunk from PNG
2. Load WASM executor (embedded or shared)
3. Copy bytecode to WASM memory
4. Call init():
   - Parse bytecode
   - Emit CREATE_SHADER, CREATE_RENDER_PIPELINE to command buffer
5. gpu.js executes: device.createShaderModule(), device.createRenderPipeline()
6. Per-frame: Call frame(time, width, height):
   - Emit BEGIN_RENDER_PASS, SET_PIPELINE, DRAW, END_PASS, SUBMIT
7. gpu.js executes: encoder.beginRenderPass(), pass.draw(), queue.submit()
```

---

## Ping-Pong Buffer Pattern

For compute simulations (boids, particles), use pool buffers:

**DSL:**
```
#buffer particles {
  size=32768
  usage=[VERTEX STORAGE]
  pool=2                    // Creates particles_0, particles_1
}

#bindGroup simBindGroup {
  layout={ pipeline=computePipe index=0 }
  entries=[
    { binding=0 buffer=particles pingPong=0 }  // Read from
    { binding=1 buffer=particles pingPong=1 }  // Write to
  ]
  pool=2                    // Alternates each frame
}
```

**Selection formula:**
```
actual_id = base_id + (frame_counter + offset) % pool_size
```

**Frame 0:**
- Read from particles_0, write to particles_1
- Render from particles_1

**Frame 1:**
- Read from particles_1, write to particles_0
- Render from particles_0

---

## ID Systems

Multiple ID systems exist for different purposes:

| ID Type | Scope | Purpose | Example |
|---------|-------|---------|---------|
| `data_id` | Data Section | Index into blob array | `data_id=0` → first blob |
| `wgsl_id` | WGSL Table | Index into WGSL module table | Maps to data_id + deps |
| `string_id` | String Table | Interned string index | Entry point names |
| `resource_id` | Emitter | Logical GPU resource | `buffer_id=5` |

**Critical**: The executor uses `data_id` for data lookups. When emitting
`create_shader_module`, pass `data_id`, not `wgsl_id`.

---

## Command Buffer Format

**Header (8 bytes):**
```
[total_len: u32]    Total buffer size including header
[cmd_count: u16]    Number of commands
[flags: u16]        Reserved
```

**Command format:**
```
[opcode: u8][args...]

Example: CREATE_BUFFER
[0x01][id:u16][size:u32][usage:u8]

Example: DRAW
[0x15][vertex_count:u32][instance_count:u32][first_vertex:u32][first_instance:u32]
```

**Benefits:**
- One WASM→JS transition per frame (not per command)
- Same format across all platforms
- Simple switch statement in host

---

## Module Dependency Graph

```
src/types/           Zero dependencies, shared types
    │
    ├── opcodes.zig      PNGB opcode enum
    ├── plugins.zig      PluginSet definition
    └── descriptors.zig  Shared descriptor types
    │
    ▼
src/bytecode/        Depends on types/
    │
    ├── format.zig       PNGB serialization
    ├── emitter.zig      Low-level bytecode emission
    └── data_section.zig Blob storage
    │
    ▼
src/executor/        Depends on bytecode/
    │
    ├── dispatcher.zig   Bytecode interpretation
    ├── command_buffer.zig  Command output
    └── plugins/*.zig    Feature implementations
    │
    ▼
src/dsl/             Depends on all above
    │
    ├── Lexer.zig        Tokenization
    ├── Parser.zig       AST construction
    ├── Analyzer.zig     Semantic analysis
    └── Emitter.zig      Code generation
    │
    ▼
src/wasm_entry.zig   WASM exports, uses executor/
```

---

## Test Strategy

**Standalone modules (1,114 tests):**
```bash
zig build test-standalone --summary all
```

| Module | Tests | What It Covers |
|--------|-------|----------------|
| types | 10 | Type definitions, PluginSet |
| bytecode | 147 | Format, opcodes, serialization |
| executor | 114 | Dispatcher, command buffer |
| dsl-complete | 514 | Full compilation pipeline |

**When to use each:**
- `test-executor`: Changing dispatcher or command buffer
- `test-dsl-complete`: Changing emitter or adding features
- `test-standalone`: Full validation before commit

---

## File Size Reference

| Component | Size | Notes |
|-----------|------|-------|
| WASM executor (shared) | 57 KB | All plugins |
| WASM executor (tailored) | ~15 KB | Goal with plugin selection |
| browser.mjs (JS bundle) | 24 KB | 8 KB gzipped |
| Simple triangle PNGB | ~500 B | Minimal example |
| Boids simulation PNGB | ~2 KB | Compute + render |

---

## Key Files Quick Reference

| Purpose | File | Lines |
|---------|------|-------|
| **Compilation** | | |
| DSL Compiler entry | `src/dsl/Compiler.zig` | 1,236 |
| Tokenizer | `src/dsl/Lexer.zig` | ~400 |
| Parser | `src/dsl/Parser.zig` | 1,111 |
| Semantic analysis | `src/dsl/Analyzer.zig` | 1,663 |
| Bytecode emission | `src/dsl/Emitter.zig` | ~500 |
| | | |
| **Format** | | |
| PNGB serialization | `src/bytecode/format.zig` | 1,422 |
| PNGB opcodes | `src/types/opcodes.zig` | 372 |
| Command buffer | `src/executor/command_buffer.zig` | 791 |
| | | |
| **Runtime** | | |
| WASM entry | `src/wasm_entry.zig` | 1,103 |
| Bytecode dispatcher | `src/executor/dispatcher.zig` | ~1,500 |
| JS command executor | `npm/pngine/src/gpu.js` | 697 |
| | | |
| **Embedding** | | |
| PNG embedding | `src/png/embed.zig` | ~200 |
| PNG extraction | `src/png/extract.zig` | ~200 |

---

## Common Pitfalls for LLMs

These are the most frequent bugs encountered when modifying PNGine:

### 1. Confusing ID Systems

**Bug**: Passing `wgsl_id` where `data_id` is expected.

**Symptom**: Shader creation gets expression string instead of WGSL code.

**Fix**: In emitter code, always use `data_id.toInt()` for data section lookups,
not the WGSL table index.

### 2. Confusing Opcode Sets

**Bug**: Adding opcode to wrong file or using wrong value.

**Check**:
- Bytecode stored in file → `src/types/opcodes.zig`
- Commands to JS host → `src/executor/command_buffer.zig`

### 3. pngineInputs Buffer Size

**Bug**: Creating 12-byte buffer for 16-byte pngineInputs.

**Fix**: Always size uniform buffers to exactly 16 bytes:
```
#buffer uniforms { size=16 usage=[UNIFORM COPY_DST] }
```

### 4. Stack Pointer in Command Buffer

**Bug**: Passing pointer to stack-allocated data to command buffer.

**Symptom**: JavaScript reads zeros because stack is stale.

**Fix**: Copy data inline into command buffer, not just a pointer.

### 5. Missing Plugin Detection

**Bug**: Adding feature that requires plugin but not detecting it in Analyzer.

**Fix**: Update `detectPlugins()` in Analyzer.zig when adding features that
need render, compute, wasm, animation, or texture plugins.

See `CONTRIBUTING.md` for detailed debugging strategies.

---

## Related Documents

- `CLAUDE.md` - Development guide with commands and conventions
- `CONTRIBUTING.md` - Debugging strategies and common pitfalls (read this!)
- `docs/embedded-executor-plan.md` - Plugin architecture details
- `docs/cpu-wasm-data-initialization-plan.md` - Buffer init approaches
