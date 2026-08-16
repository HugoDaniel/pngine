# PNGine Architecture

A reference to the machinery: compiler, bytecode, executor and runtime.
Assumes a working knowledge of WebGPU and WASM.

---

## Summary

PNGine is a **WebGPU bytecode engine** that compiles SJON source (`.sjon`,
schema-driven S-expressions) into compact bytecode (PNGB) embedded in PNG
files. The key architectural insight is the separation of concerns:

- **Heavy Compiler (Zig)**: Runs once at build time, unlimited complexity
- **Minimal Payload (PNGB)**: Declarative bytecode + data, size-constrained
- **Tiny Executor (WASM)**: Interprets bytecode, emits GPU commands. 13,331 B
  for the full plugin set, under a build-enforced 13,600 cap; eight variants,
  smallest 9,009 B
- **Platform Viewer**: Executes GPU commands on a real WebGPU implementation —
  the browser, or wgpu-native/Metal for the CLI's `--frame`

```
                    COMPILE TIME                    RUNTIME
                        │                              │
     .sjon source ──► Compiler ──► PNG ──► Executor ──► GPU
       (SJON)          (Zig)     (PNGB)    (WASM)    (WebGPU)
                        │           │          │          │
                    Heavy work   Stored    Tiny work   Platform
                    (once)       (~13KB)   (per-frame)  native
```

**Scope note**: this document describes the *engine* — the four boxes above.
The browser editor (pstudio) is a separate project that consumes this engine
from the npm registry like any other user. Nothing in `src/` or `build.zig`
builds against it, but the engine carries **downstream-coupling notes** where
a change here would break it — see the `UniformType` comment in
`src/bytecode/uniform_table.zig`. No build edge crosses the repo boundary, so
those comments are the only warning you get. Honour them.

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
│   - Descriptors (JSON or binary TLV — see below)                │
│   - Embedded WASM modules (data-generator WASM)                 │
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

### Descriptor encoding: JSON or binary

Two encodings live side by side in the data section. Which one a descriptor
uses is decided by the **shape of its WebGPU dictionary**, and both choices are
frozen per opcode by [abi.md](abi.md) §6.1–6.5:

| Shape | Encoding | Descriptors |
|-------|----------|-------------|
| Flat — fixed, shallow scalars and enums | binary TLV (`descriptor_encoder.zig`) | texture, sampler, texture view, bind-group entries, **compute** pipeline, render bundle |
| Nested — arrays of dictionaries of optional dictionaries | JSON (hand-built in `Emitter.zig`, `JSON.parse`d by gpu.js) | **render** pipeline, bind-group **layout**, pipeline layout |

A flat `[tag][field][value]` table encodes the first group exactly and
compactly, and those are the numerous ones. It cannot express the second group
without a bespoke nested sub-schema per descriptor — and gpu.js passes most of
the parsed object to WebGPU verbatim, so there the JSON *is* the descriptor.

This is why a bind group is binary while its layout is JSON: a bind-group entry
is a fixed `[binding][type][id]` row, a layout entry is a dictionary with four
mutually-exclusive optional sub-dictionaries. Same reason a compute pipeline is
binary while a render pipeline is JSON.

Because the split is part of the frozen v1 executor↔JS ABI, moving a descriptor
from one encoding to the other is an ABI break, not a refactor. Extend
additively: a new TLV field ID, or a new JSON key.


**Source files:**
- `src/bytecode/format.zig` - Header and serialization (~1,400 lines)
- `src/bytecode/opcodes.zig` - PNGB opcode definitions
- `src/bytecode/data_section.zig` - Data blob storage
- `src/bytecode/string_table.zig` - Interned strings
- `src/png/embed.zig` - Embed bytecode as pNGb chunk

### 2. The Executor

The **executor** is a WASM module that interprets PNGB bytecode and emits GPU
commands. There are two delivery mechanisms:

**Delivery Options:**
| Method | When Used | Location | Notes |
|--------|-----------|----------|-------|
| **In payload** | CLI default | Inside PNGB bytecode | Self-contained PNG; JS loader auto-detects it |
| **Shared** | `--no-executor` builds | External `pngine.wasm` file | Fallback for PNGs without an embedded executor |

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
- `src/wasm_entry.zig` - WASM entry points
- `src/executor/dispatcher.zig` - Bytecode interpretation (+ `dispatcher/` handlers)
- `src/executor/command_buffer.zig` - Command buffer format

### 3. The Plugin Architecture

Executors are tailored per-payload based on DSL analysis. Only needed code is
included, reducing WASM size.

**Plugins:**
| Plugin | When Included | Features |
|--------|---------------|----------|
| `core` | Always | Bytecode parsing, buffer creation, command emission |
| `render` | `(render-pipeline …)`, `(render-pass …)` | Render pipelines, draw commands |
| `compute` | `(compute-pipeline …)`, `(compute-pass …)` | Compute pipelines, dispatch |
| `wasm` | WASM data buffers (`:data`, `(data … wasm)`) | Nested WASM execution |
| `animation` | Animation/scene forms | Scene timeline, transitions |
| `texture` | `(texture …)` with external source | Image/video texture loading |

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

The **compiler** transforms SJON source into PNGB bytecode. PNGine is a *SJON
host*: the sibling SJON package owns syntax, validation, cross-reference
resolution, expressions, and sugar lowering; PNGine owns the WebGPU schema
(`schema/pngine.sjon`), the `pngine/*` lowering hooks, and PNGB emission. It
runs once at build time with unlimited complexity:

**Compilation Pipeline:**
```
.sjon source
    │
    ▼ SJON parse (SJON package)
   forest of forms
    │
    ▼ Validate against schema/pngine.sjon
   resolved cross-refs + diagnostics
    │
    ▼ Lowering hooks (hooks.zig: pngine/init-v1, pngine/pass-v1)
   sugar expanded into ordinary forms
    │
    ▼ Emitter walk (Emitter.zig)
   PNGB bytecode
    │
    ▼ PNG embed (embed.zig)
   PNG with pNGb chunk
```

**Compiler Responsibilities:**
- Validate forms against the WebGPU schema (required keys, enums, bounds)
- Resolve bare-identifier cross-references document-wide
- Evaluate bounded expressions (`(* NUM 4 4)`, `(ceil (/ NUM 64))`)
- Generate vertex data from shape generators (`(cube …)`, `(plane …)`, `(teapot …)`)
- Determine required plugins
- Embed executor WASM (default; opt out with `--no-executor`)
- Compress payload with DEFLATE

**Source files:**
- `src/dsl_sjon/Compiler.zig` - High-level compile() interface (validate + lower → walk → PNGB)
- `src/dsl_sjon/Emitter.zig` - Walks the validated/lowered forest, emits bytecode
- `src/dsl_sjon/values.zig` - Typed readers over the SJON tree + expression eval
- `src/dsl_sjon/hooks.zig` - `pngine/init-v1` + `pngine/pass-v1` sugar lowering
- `src/dsl_sjon/uniforms.zig` - Uniform-table construction
- `src/dsl_sjon/shapes.zig` - Compile-time shape generators
- `schema/pngine.sjon` - The WebGPU schema (single source of truth)

### 5. Minimal Viewer Runtimes

**Viewers** execute command buffers on native GPU APIs. They need minimal code
because the executor handles interpretation.

**Browser Viewer (npm/pngine):**
```
PNG file ─► init.js ─► extract.js ─► worker.js ─► gpu.js ─► WebGPU
              │            │             │           │
           Spawn       Extract       Run WASM    Execute
           worker      pNGb chunk    per-frame   commands
              │
              └──► Fetch pngine.wasm (shared executor)
```

**PNG Chunks:**

PNGine stores its payloads in ancillary PNG chunks under the `pNG*` namespace
(`pNG` + a family letter). All are ancillary/public/safe-to-copy and share a
2-byte header (`version:u8`, `flags:u8`) ahead of their (optionally DEFLATE'd)
payload. Writers live in `src/png/embed.zig`; the read side is deliberately
split by consumer, so **not every chunk is read by every runtime** — the table
below is the source of truth for that asymmetry.

| Chunk  | Contents | Written by | Read by |
|--------|----------|------------|---------|
| `pNGb` | PNGB bytecode (executor WASM embedded inside by default) | `embed`, `embedWithMetadata` | Native CLI `extract` + JS runtime (`extract.js`) |
| `pNGm` | Animation metadata (JSON) | `embedWithMetadata` | **Reserved** — written, no runtime reads it |
| `pNGa` | Audio WASM module (e.g. a compiled song) | `embedAudio` | JS runtime only (`extract.js`, `viewer-init.js`) |
| `pNGf` | Flat command buffer (pre-flattened init+frame, inline data) | `embedFlat` | JS runtime only (mini viewer, `mini.js`) |
| `pNGw` | DEFLATE'd WGSL source (for `--html` compression) | **Reserved** — declared, never written | — |

**Read-side symmetry (A7):** the native `extract` command's job is bytecode, so
by design it only *decodes* `pNGb`; `pNGa`/`pNGf` are decoded by the JS runtime
at load, and `pNGm`/`pNGw` are reserved. So no single runtime
reads everything `embed` can write — but `extract` must still be able to *see*
the whole inventory. `extract.enumerateChunks` (CLI: `pngine extract <png>
--list`) enumerates every `pNG*` chunk present (type, size, version, compressed
flag), matching the `pNG` prefix so a new family is listed without a code
change. Add a new chunk → add its row here and a `chunkRole` label in
`cli/embed.zig`.

**Key JS files:**
- `npm/pngine/src/init.js` - Main thread initialization
- `npm/pngine/src/extract.js` - Extract pNGb from PNG/ZIP
- `npm/pngine/src/worker.js` - WebWorker entry point
- `npm/pngine/src/gpu.js` - Command dispatcher
- `npm/pngine/src/loader.js` - Parse v0 header, extract embedded executor

**Native execution:**
- `src/executor/wgpu_native_gpu.zig` — wgpu-native on Metal, the backend
  behind CLI `--frame`. Built with `-Dgpu-native`, which defaults on when a
  macOS host has `vendor/wgpu-native/lib/libwgpu_native.a`; the published npm
  binaries are cross-compiled without it and `--frame` hard-errors there with
  rebuild instructions.
- `tools/viewers/native/` — desktop viewer, WAMR-hosted. It traces command
  buffers; it does not render.
- The runtime for wasm is WAMR, and the GPU API is wgpu-native.

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

0x20-0x2F: Queue / WASM Operations
  0x20 write_buffer
  0x24 submit
  0x26 init_wasm_module
  0x27 call_wasm_func
  0x2A write_time_uniform

0x30-0x3F: Frame Control
  0x30 define_frame
  0x32 exec_pass
  0x35 exec_pass_once

0x40-0x52: Pool + Pass-State Operations
  0x41 set_vertex_buffer_pool
  0x42 set_bind_group_pool
  0x4A set_pass_timestamp_writes
  0x4E set_stencil_reference
  0x4F set_scissor_rect
  0x50 set_pass_depth_stencil_ops
  0x52 set_pass_clear_values
```
(This is a representative sample, not the exhaustive set — the OpCode enum in
`src/types/opcodes.zig` is authoritative.)

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

0x4A-0x52: Extended Pass State (number-identical to the PNGB opcodes)
  0x4A set_pass_timestamp_writes
  0x50 set_pass_depth_stencil_ops
  0x52 set_pass_clear_values

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

## SJON to WebGPU Mapping

The SJON forms provide 1:1 mapping to WebGPU concepts with ergonomic syntax
(see `schema/pngine.sjon` for the authoritative vocabulary):

### Resource Forms

| SJON Form | WebGPU Concept | Example |
|-----------|----------------|---------|
| `(buffer …)` | `GPUBuffer` | `(buffer :name vb :size 1024 :usage [vertex])` |
| `(texture …)` | `GPUTexture` | `(texture :name depth :format depth24plus)` |
| `(sampler …)` | `GPUSampler` | `(sampler :name samp :mag-filter linear)` |
| `(shader-module …)` | `GPUShaderModule` | `(shader-module :name code :code """…""")` |
| `(bind-group …)` | `GPUBindGroup` | `(bind-group :name bg … (entry :binding 0 :buffer u))` |
| `(render-pipeline …)` | `GPURenderPipeline` | `(render-pipeline :name pipe (vertex …) …)` |
| `(compute-pipeline …)` | `GPUComputePipeline` | `(compute-pipeline :name cp :module code :entry main)` |

### Pass Forms

| SJON Form | WebGPU Concept | Key Properties |
|-----------|----------------|----------------|
| `(render-pass …)` | `GPURenderPassEncoder` | `(color-attachment …)`, `:pipeline`, `(draw …)` |
| `(compute-pass …)` | `GPUComputePassEncoder` | `:pipeline`, `:dispatch-workgroups` |
| `(queue …)` | `GPUQueue.writeBuffer()` | `(write-buffer :buffer … :data …)` |

### Frame Form

| SJON Form | Purpose | Example |
|-----------|---------|---------|
| `(frame …)` | Define execution order | `(frame :name main :perform [pass1 pass2])` |

### Execution Model

```
(frame :name main
  :before [setupQueue]              ; queue ops run before each frame
  :init [initCompute]               ; run once (exec_pass_once)
  :perform [computePass renderPass]) ; run every frame
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
| `pngine-inputs` | 16 bytes | time(f32), width(f32), height(f32), aspect(f32) |
| `scene-time-inputs` | 12 bytes | time, width, height (the first 12 bytes of `pngine-inputs`) |
| `pointer-inputs` | 48 bytes | pointer x/y, click, deltas, buttons, pressure, scroll |
| `context-current-texture` | - | Canvas texture for render pass |

---

## Data Flow: Complete Example

**Simple Triangle (examples/simple_triangle.sjon):**

```
(shader-module :name code :code """
@vertex fn vertexMain(...) -> @builtin(position) vec4f { ... }
@fragment fn fragMain() -> @location(0) vec4f { ... }
""")

(render-pipeline :name pipeline
  (layout auto)
  (vertex (module code) (entry vertexMain))
  (fragment (module code) (entry fragMain)
    (targets (target :format preferred-canvas-format)))
  (primitive (topology triangle-list)))

(render-pass :name renderPipeline
  (color-attachment :view context-current-texture :clear-value [0 0 0 0] :load-op clear :store-op store)
  :pipeline pipeline
  (draw :vertex-count 3))

(frame :name simpleTriangle :perform [renderPipeline])
```

**Compilation:**
```
1. SJON parse: forest of 4 forms
2. Validate against schema/pngine.sjon: cross-refs resolved (code, pipeline)
3. Lowering hooks: nothing to expand (no sugar used)
4. Emitter walk:
   - create_shader_module(0, data_id=0)
   - create_render_pipeline(0, desc_data_id=1)
   - define_frame(0, name_id=0)
   - exec_pass(0)  // points to pass definition
   - end_frame
5. Output: ~400 bytes PNGB
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

**SJON:**
```
(buffer :name particles
  :size 32768
  :usage [vertex storage]
  :pool 2)                  ; creates particles_0, particles_1

(bind-group :name simBindGroup
  :layout-pipeline computePipe :layout-index 0 :pool 2  ; alternates each frame
  (entry :binding 0 :buffer particles :ping-pong 0)   ; read from
  (entry :binding 1 :buffer particles :ping-pong 1))  ; write to
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
[0x01][id:u16][size:u32][usage:u16]

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
src/dsl_sjon/        Depends on all above (+ the SJON package + wgslender)
    │
    ├── Compiler.zig     compile(): validate + lower → walk → PNGB
    ├── Emitter.zig      Walks validated forms, emits bytecode
    ├── values.zig       Typed readers + expression eval
    ├── hooks.zig        pngine/init-v1 + pngine/pass-v1 lowering
    └── shapes.zig       Compile-time shape generators
    │
    ▼
src/wasm_entry.zig   WASM exports, uses executor/
```

---

## Test Strategy

**Standalone modules (run in parallel):**
```bash
zig build test-standalone --summary all
```

Key modules: `test-types`, `test-bytecode`, `test-executor`, `test-sjon`
(compiler + emitter), `test-sjon-golden` (frozen MockGPU call-log traces),
`test-sjon-invalid` (validator-rejection negatives).

**When to use each:**
- `test-executor`: Changing dispatcher or command buffer
- `test-sjon` + `test-sjon-golden`: Changing emitter or adding features
- `test-standalone`: Full validation before commit

---

## File Size Reference

| Component | Size | Notes |
|-----------|------|-------|
| WASM executor (full) | 13,331 B | All plugins; build-enforced 13,600 cap |
| WASM executor (core) | 9,009 B | Smallest of the eight variants |
| `viewer.mjs` (default JS bundle) | 49.0 KB | 16.9 KB gzipped |
| `mini.mjs` | 7.0 KB | 3.2 KB gzipped; pNGf, main thread, no WASM |
| Simple triangle PNGB | ~500 B | Minimal example |
| Boids simulation PNGB | ~5 KB | Compute + render |

Bundle figures come from the table in `docs/publishing.md`, which
`zig build drift` checks against the bundler's own budgets. Executor figures
come from `build.zig`'s budget guard, which prints them on every build.

---

## Key Files Quick Reference

| Purpose | File |
|---------|------|
| **Compilation** | |
| SJON compile entry | `src/dsl_sjon/Compiler.zig` |
| Bytecode emission (walk) | `src/dsl_sjon/Emitter.zig` |
| Typed value readers | `src/dsl_sjon/values.zig` |
| Sugar lowering hooks | `src/dsl_sjon/hooks.zig` |
| WebGPU schema | `schema/pngine.sjon` |
| **Format** | |
| PNGB serialization | `src/bytecode/format.zig` |
| PNGB opcodes | `src/types/opcodes.zig` |
| Command buffer | `src/executor/command_buffer.zig` |
| **Runtime** | |
| WASM entry | `src/wasm_entry.zig` |
| Bytecode dispatcher | `src/executor/dispatcher.zig` |
| JS command executor | `npm/pngine/src/gpu.js` |
| **Embedding** | |
| PNG bytecode embed (pNGb) | `src/png/embed.zig` |
| PNG extraction | `src/png/extract.zig` |

---

## Common Pitfalls

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

### 3. pngine-inputs Buffer Size

**Bug**: Creating 12-byte buffer for 16-byte `pngine-inputs`.

**Fix**: Always size uniform buffers to exactly 16 bytes:
```
(buffer :name uniforms :size 16 :usage [uniform copy-dst])
```

### 4. Stack Pointer in Command Buffer

**Bug**: Passing pointer to stack-allocated data to command buffer.

**Symptom**: JavaScript reads zeros because stack is stale.

**Fix**: Copy data inline into command buffer, not just a pointer.

### 5. Missing Plugin Detection

**Bug**: Adding feature that requires plugin but not detecting it.

**Fix**: There is no separate detection pass. `bytecode/emitter.zig`
accumulates `plugins_used` as it emits, and `Compiler.zig` reads it off the
builder. A new feature that needs render, compute, wasm, animation or texture
support must set its bit at the emission site, or the payload ships a variant
that cannot run it.

---

## Related Documents

- `docs/sjon-reference.md` - The `.sjon` authoring reference
- `docs/abi.md` - The frozen executor WASM↔JS ABI
- `docs/publishing.md` - npm package layout and publishing
- `examples/README.md` - The example corpus

---

## Runtime Pipeline (Detailed)

Understanding where code runs and what each component can do is critical for
making architectural decisions (like where to put mesh generators).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           BUILD TIME (once)                                  │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Compiler (Zig)                                                      │   │
│  │  - Parses SJON source (.sjon)                                        │   │
│  │  - Resolves references, validates semantics                          │   │
│  │  - CAN run arbitrary Zig code (mesh generators, etc.)                │   │
│  │  - Emits bytecode opcodes + data section                             │   │
│  │  - Complexity: unlimited (runs once on developer machine)            │   │
│  └────────────────────────────┬─────────────────────────────────────────┘   │
│                               │                                              │
│                               ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Payload (.pngb embedded in PNG)                                     │   │
│  │  - Declarative bytecode (WHAT to create, not HOW)                    │   │
│  │  - WGSL shader code as strings                                       │   │
│  │  - Static vertex data, textures, initial buffer values               │   │
│  │  - Resource descriptors (sizes, formats, bindings)                   │   │
│  │  - NO executable code (just data + opcodes)                          │   │
│  │  - Size constraint: should be <50KB total for practical use          │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ Distributed (PNG file)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          LOAD TIME (once per instance)                       │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Executor (WASM, ~15KB)                                               │   │
│  │  - Parses bytecode header and opcodes                                │   │
│  │  - Dispatches commands to gpu.js via extern functions                │   │
│  │  - Manages frame loop and pass execution                             │   │
│  │  - CANNOT generate data (no mesh generators, no math)                │   │
│  │  - MUST stay tiny: goal is ~15KB                                     │   │
│  │  - Static allocation only (no malloc after init)                     │   │
│  └────────────────────────────┬─────────────────────────────────────────┘   │
│                               │                                              │
│                               │ extern "env" fn gpuCreateBuffer(...)        │
│                               ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  gpu.js (CommandDispatcher, ~1200 lines)                             │   │
│  │  - Implements actual WebGPU API calls                                │   │
│  │  - Creates GPUBuffer, GPUPipeline, GPUBindGroup, etc.                │   │
│  │  - CAN run arbitrary JavaScript                                      │   │
│  │  - CAN have helper functions (runtime mesh generators OK here)       │   │
│  │  - Handles platform adaptation (canvas formats, device limits)       │   │
│  │  - Already bundled with app, so +150 lines is marginal               │   │
│  └────────────────────────────┬─────────────────────────────────────────┘   │
│                               │                                              │
│                               │ device.createBuffer(), etc.                  │
│                               ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  GPU Resources                                                       │   │
│  │  - GPUBuffer, GPUTexture, GPUSampler                                 │   │
│  │  - GPURenderPipeline, GPUComputePipeline                             │   │
│  │  - GPUBindGroup, GPUBindGroupLayout                                  │   │
│  │  - Ready for rendering                                               │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ Resources ready
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          FRAME TIME (60fps)                                  │
│                                                                              │
│  Executor → gpu.js → GPU                                                     │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  GPU (WGSL shaders)                                                  │   │
│  │  - Vertex/Fragment shaders (every frame)                             │   │
│  │  - Compute shaders (simulation, particles, etc.)                     │   │
│  │  - Initialization compute (runOnce=true, first frame only)           │   │
│  │  - Massively parallel, extremely fast                                │   │
│  │  - CAN generate any data (noise, particles, transforms)              │   │
│  │  - WGSL code compresses well (~150 bytes for particle init)          │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component    | When   | Can Generate Data? | Size Constraint | Complexity OK? |
| ------------ | ------ | ------------------ | --------------- | -------------- |
| **Compiler** | Build  | Yes (Zig code)     | No limit        | Yes            |
| **Payload**  | Stored | No (just data)     | <50KB           | N/A            |
| **Executor** | Load   | No                 | ~15KB goal      | No             |
| **gpu.js**   | Load   | Yes (JS helpers)   | ~50KB OK        | Yes            |
| **GPU**      | Frame  | Yes (compute)      | N/A             | Yes (parallel) |

### Data Flow for Resource Creation

```
Opcode in payload:  CREATE_BUFFER { id=5, size=32768, usage=VERTEX|STORAGE }
        │
        ▼
Executor (WASM):    reads opcode, extracts params, calls extern fn
        │
        │  gpuCreateBuffer(5, 32768, 0xA0)
        ▼
gpu.js:             creates actual WebGPU resource
        │
        │  device.createBuffer({ size: 32768, usage: ... })
        ▼
GPU:                buffer exists, ready for use
```

### Where to Put Mesh Generators

Given the architecture, there are 3 viable places for mesh generators:

| Location           | Payload Size         | When Runs   | Adds Code To  |
| ------------------ | -------------------- | ----------- | ------------- |
| **Compiler (Zig)** | ~400B (vertex data)  | Build time  | Compiler only |
| **gpu.js (JS)**    | ~10B (opcode+params) | Load time   | JS bundle     |
| **GPU (WGSL)**     | ~150B (shader code)  | First frame | Payload       |

**Decision Framework:**

1. **Standard meshes (cube, sphere, plane)** → Compiler (procedural shapes)
   - Compiler: simple, no runtime code changes
   - Deindexed output, vertex buffer only

2. **Classic test meshes (teapot, dragon)** → Compiler (static indexed meshes)
   - Pre-baked binary data via `@embedFile` (in `src/dsl_sjon/meshes/`)
   - Indexed output: separate vertex + index buffers (significant size savings)
   - Normals pre-computed in conversion script (`scripts/convert-meshes.mjs`)

3. **Large procedural data (particles, noise, heightmaps)** → GPU compute
   - WGSL compresses well
   - Runs in parallel
   - Uses existing compute infrastructure

4. **Small static data (<2KB)** → Compiler
   - Inline in payload
   - No runtime overhead

### Key Insight: Payload is Data, Not Code

The payload (.pngb) should be **declarative, not imperative**:

- **YES**: "create a buffer with these bytes" (data)
- **YES**: "run this WGSL shader" (GPU-executed code)
- **NO**: "generate cube vertices using this algorithm" (CPU-executed code)

The payload cannot contain executable code that runs on the CPU. It can only:

1. Contain static data (vertices, textures, parameters)
2. Reference WGSL code (executed by GPU, not payload)
3. Describe resources and their relationships

This means **compile-time generators cannot be "moved to the payload"** in a
literal sense. Instead, the choice is where the generator _runs_:

| Approach     | Generator Runs In | Payload Contains |
| ------------ | ----------------- | ---------------- |
| Compile-time | Compiler (Zig)    | Generated bytes  |
| Runtime JS   | gpu.js            | Opcode + params  |
| Runtime GPU  | GPU (WGSL)        | WGSL source      |

For the **runtime JS** approach, we would:

1. Add a new opcode like `FILL_CUBE_MESH { bufferId, size, format }`
2. Implement `_fillCubeMesh()` in gpu.js
3. Compiler emits the opcode instead of vertex bytes
4. Payload shrinks from ~400B to ~10B

This is viable because gpu.js already runs at load time and can have helper
functions.

