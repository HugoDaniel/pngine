# PNGine Bytecode and Minimal Runtime Architecture

## Overview

This document specifies the new bytecode-based interpreter that replaces the JSON array instruction format. The interpreter is written in Zig, compiled to WebAssembly, and embedded in PNG files alongside scene data.

**Based on:** `/Users/hugo/Development/old_pngine/docs/NEW_INTERPRETER.md`

---

## The Problem: 1.7MB for 644 Instructions

Analysis of a production demo (`inercia2025/demo_instructions.json`) reveals severe inefficiency:

| Metric | Value |
|--------|-------|
| File size | 1.7MB |
| Instruction count | 644 |
| Average per instruction | **2.6KB** |
| Shader code (embedded) | 819KB (47.7%) |
| Path strings | 863KB (50.3%) |
| Keywords (`$`, `set`, etc.) | 7KB (0.4%) |

**Target: 30x Reduction**

With bytecode + data section separation: **1.7MB → ~50KB instructions + compressed data**

---

## Dual Format Architecture

PNGine uses two representations of the same bytecode, similar to WebAssembly's `.wat` and `.wasm`:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PNGine Compilation Pipeline                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  .pngine.wgsl ──────► .pbsf (S-Expression) ◄────► .pngb (Binary)           │
│  (DSL Source)         (Text Format)                (Binary Format)          │
│                       Human/LLM readable           Size-optimized           │
│                                                    Embedded in PNG          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Text Format: PBSF (PNGine Bytecode S-Expression Format)

S-expression syntax optimized for human and LLM readability:

```lisp
(module "scene"
  (buffer $buf:0 (size 1024) (usage uniform copy-dst))
  (shader $shd:0 (code $d:0))
  (render-pipeline $pipe:0
    (vertex $shd:0 (entry "vs"))
    (fragment $shd:0 (entry "fs")))
  (pass $pass:0 "main"
    (render
      (color-attachments (attachment (view @swapchain) (load clear) (store store)))
      (commands
        (set-pipeline $pipe:0)
        (draw (vertices 3) (instances 1)))))
  (frame $frm:0 "main"
    (exec-pass $pass:0)
    (submit)))
```

**Used for**: Debugging, LLM generation, version control diffs, documentation.

### Binary Format: PNGB (PNGine Binary)

Flat opcode stream optimized for size and execution speed:

```
01 00 04 00 48  ;; CreateBuffer id:0 size:1024 usage:0x48
04 00 00        ;; CreateShader id:0 code:data0
08 00 ...       ;; CreatePipeline id:0 ...
30 00 00        ;; DefineFrame id:0 name:str0
32 00           ;; ExecPass pass:0
24              ;; Submit
31              ;; EndFrame
```

**Used for**: PNG embedding, runtime execution.

### Why Two Formats?

| Aspect | S-Expression (Text) | Binary |
|--------|---------------------|--------|
| **Purpose** | Human/LLM readability | Minimal size |
| **Structure** | Hierarchical, nested | Flat, sequential |
| **Parameters** | Named: `(size 1024)` | Positional: `04 00` |
| **References** | Typed: `$buf:0` | Raw IDs: `00` |
| **Parsing** | Trivial S-expr parser | Direct byte reading |
| **Size** | ~10x larger than binary | Minimal |

**They represent identical semantics**—the assembler/disassembler converts between them losslessly.

---

## Why Register-Based Over Stack-Based

### The Workload

PNGine dispatches GPU API calls, not arithmetic:

```
CreateBuffer(id=0, size=1024, usage=32)
CreatePipeline(id=0, shader=0, ...)
BeginFrame(id=0)
  SetPipeline(0)
  Draw(3, 1)
EndFrame
```

No expression evaluation—the GPU does computation.

### Stack-Based is Wrong for API Dispatch

```
push 1024; push 32; push 0; CreateBuffer  // Which arg is which?
```

Problems:
- Implicit argument order
- Extra instructions to shuffle operands
- No natural mapping to descriptor fields

### Register-Based Maps Directly

```
CreateBuffer r0, 1024, 32   // Explicit: r0 = buffer, size=1024, usage=32
```

Resource tables ARE registers:
- `buffers[0]` → buffer register 0
- `pipelines[3]` → pipeline register 3
- `bindGroups[2]` → bind group register 2

### Context Slots (Not General Registers)

PNGine needs ~4 context slots, not 32 general registers:

```zig
const Context = struct {
    command_encoder: ?CommandEncoder,
    render_pass: ?RenderPassEncoder,
    compute_pass: ?ComputePassEncoder,
    frame_index: u32,  // For ping-pong selection
};
```

---

## Binary Format Specification

### File Structure

```
┌─────────────────────────────────────┐
│ Header (16 bytes)                   │
│   magic: "PNGB"                     │
│   version: u16                      │
│   flags: u16                        │
│   string_table_offset: u32          │
│   data_section_offset: u32          │
│   bytecode_offset: u32              │
├─────────────────────────────────────┤
│ String Table                        │
│   count: u16                        │
│   offsets: [u16; count]             │
│   data: UTF-8 bytes                 │
├─────────────────────────────────────┤
│ Data Section                        │
│   count: u16                        │
│   entries: [{offset: u32, len: u32}]│
│   data: raw bytes (shader code,     │
│         uniform layouts, etc.)      │
├─────────────────────────────────────┤
│ Bytecode                            │
│   instructions: [u8 | u16 | u32]    │
│   (variable-length encoded)         │
└─────────────────────────────────────┘
```

### Variable-Length Integer Encoding

To minimize size, use LEB128-style encoding:

| Value Range | Encoding | Bytes |
|-------------|----------|-------|
| 0-127 | `0xxxxxxx` | 1 |
| 128-16383 | `10xxxxxx xxxxxxxx` | 2 |
| 16384+ | `11xxxxxx xxxxxxxx xxxxxxxx xxxxxxxx` | 4 |

Most resource IDs fit in 1 byte. Buffer sizes need 4 bytes.

### Opcode Layout

Single-byte opcodes with inline arguments:

```
┌────────┬────────┬────────┬────────┐
│ opcode │  arg0  │  arg1  │  arg2  │
│  (u8)  │ (var)  │ (var)  │ (var)  │
└────────┴────────┴────────┴────────┘
```

---

## Opcode Definitions

```zig
const OpCode = enum(u8) {
    // Resource Creation (0x00-0x1F)
    create_buffer = 0x01,           // id, size, usage
    create_texture = 0x02,          // id, width, height, format, usage
    create_sampler = 0x03,          // id, descriptor_data_id
    create_shader_module = 0x04,    // id, code_data_id
    create_shader_concat = 0x05,    // id, count, data_ids... (WGSL composition)
    create_bind_group_layout = 0x06,
    create_pipeline_layout = 0x07,
    create_render_pipeline = 0x08,  // id, descriptor_data_id
    create_compute_pipeline = 0x09,
    create_bind_group = 0x0A,       // id, layout_pipeline, layout_index, entries...

    // Pass Operations (0x10-0x1F)
    begin_render_pass = 0x10,       // color_texture, load_op, store_op
    begin_compute_pass = 0x11,
    set_pipeline = 0x12,            // pipeline_id
    set_bind_group = 0x13,          // slot, group_id
    set_vertex_buffer = 0x14,       // slot, buffer_id
    set_index_buffer = 0x15,        // buffer_id, format
    draw = 0x16,                    // vertex_count, instance_count
    draw_indexed = 0x17,            // index_count, instance_count
    dispatch = 0x18,                // x, y, z
    end_pass = 0x19,

    // Queue Operations (0x20-0x2F)
    write_buffer = 0x20,            // buffer_id, offset, data_id
    write_uniform = 0x21,           // buffer_id, uniform_id (runtime-resolved)
    copy_buffer_to_buffer = 0x22,
    copy_texture_to_texture = 0x23,
    submit = 0x24,

    // Frame Control (0x30-0x3F)
    define_frame = 0x30,            // frame_id, name_string_id
    end_frame = 0x31,
    exec_pass = 0x32,               // pass_id
    define_pass = 0x33,             // pass_id, type, descriptor_data_id
    end_pass_def = 0x34,

    // Pool Operations (0x40-0x4F)
    select_from_pool = 0x40,        // dest_slot, pool_id, offset

    // Data Array Operations (0x50-0x5F) - Runtime Data Generation
    create_typed_array = 0x50,      // type, id, element_count
    fill_constant = 0x51,           // arr, offset, count, stride, value
    fill_random = 0x52,             // arr, offset, count, stride, seed, min, max
    fill_linear = 0x53,             // arr, offset, count, stride, start, step
    fill_element_index = 0x54,      // arr, offset, count, stride, scale, offset
    fill_expression = 0x55,         // arr, offset, count, stride, expr_len, expr_bytecode
    init_buffer_from_array = 0x58,  // buffer_id, array_id
    write_array_to_buffer = 0x59,   // buffer_id, buf_offset, arr_id, arr_offset, size

    // Expression VM (0x60-0x7F) - Per-element Math
    expr_push_const = 0x60,         // Push f32 constant (next 4 bytes)
    expr_push_element_id = 0x61,    // Push current element index
    expr_push_element_count = 0x62, // Push total element count
    expr_push_random = 0x63,        // Push seeded random [0,1)
    expr_dup = 0x64,                // Duplicate top
    expr_swap = 0x65,               // Swap top two
    expr_pop = 0x66,                // Discard top
    expr_add = 0x70,                // a b → (a+b)
    expr_sub = 0x71,                // a b → (a-b)
    expr_mul = 0x72,                // a b → (a*b)
    expr_div = 0x73,                // a b → (a/b)
    expr_mod = 0x74,                // a b → (a%b)
    expr_min = 0x75,                // a b → min(a,b)
    expr_max = 0x76,                // a b → max(a,b)
    expr_sin = 0x78,                // a → sin(a)
    expr_cos = 0x79,                // a → cos(a)
    expr_sqrt = 0x7A,               // a → sqrt(a)
    expr_abs = 0x7B,                // a → abs(a)
    expr_floor = 0x7C,              // a → floor(a)
    expr_fract = 0x7D,              // a → fract(a)
    expr_store = 0x7F,              // Store result, end expression

    // Runtime (0xF0-0xFF)
    update_builtins = 0xF0,         // Updates time, canvas dimensions
    nop = 0xFE,
    halt = 0xFF,
};
```

---

## CreateShaderConcat (0x05) - Runtime WGSL Composition

From RUNTIME_WGSL_COMPOSITION.md - enables shader deduplication by concatenating WGSL fragments at runtime.

### Format

```
05 <shader_id> <count> <data_ids...>
```

### PBSF Syntax

```lisp
(shader-concat $shd:3 $d:0 $d:1 $d:4)
```

This concatenates data entries 0, 1, and 4 from the data section to create shader 3.

### Use Case

Many shaders share common code:
- Preamble (struct definitions, constants)
- Utility functions (noise, transformations)
- Per-shader unique code

Instead of duplicating shared code in each shader:

**Before (duplicate code):**
```
data[0] = "struct Input { ... } fn noise() { ... } @vertex fn vs() { ... }"
data[1] = "struct Input { ... } fn noise() { ... } @fragment fn fs() { ... }"
```

**After (shared fragments):**
```
data[0] = "struct Input { ... }"           // Preamble
data[1] = "fn noise() { ... }"             // Utilities
data[2] = "@vertex fn vs() { ... }"        // Vertex-specific
data[3] = "@fragment fn fs() { ... }"      // Fragment-specific

shader[0] = concat(data[0], data[1], data[2])  // Vertex shader
shader[1] = concat(data[0], data[1], data[3])  // Fragment shader
```

### Expected Savings

From analysis of real demos: **39% reduction in shader code size**.

---

## Runtime Data Generation (0x50-0x7F)

From DATA_RUNTIME_GENERATION.md - generate procedural data at runtime instead of embedding pre-computed binary data.

### Why Runtime Generation?

| Scenario | Compile-Time (embedded) | Runtime Generation |
|----------|------------------------|-------------------|
| 4K particles (128KB) | 109KB compressed | ~100 bytes bytecode |
| 64K noise texture (256KB) | 200KB compressed | ~20 bytes bytecode |
| 1K spiral points (8KB) | 6KB compressed | ~60 bytes bytecode |

**Threshold**: Use runtime generation for arrays > 1KB.

### Fill Operations

**FillConstant (0x51):**
```lisp
(fill-const $d:0 (offset 3) (count 4096) (stride 8) (value 1.0))
```
Sets every 8th element starting at offset 3 to 1.0.

**FillRandom (0x52):**
```lisp
(fill-random $d:0 (offset 0) (count 4096) (stride 8) (seed 42) (min -10) (max 10))
```
Fills with seeded random values in range [-10, 10].

**FillLinear (0x53):**
```lisp
(fill-linear $d:0 (offset 0) (count 100) (stride 1) (start 0.0) (step 0.01))
```
Creates sequence: 0.0, 0.01, 0.02, ...

**FillElementIndex (0x54):**
```lisp
(fill-index $d:0 (offset 0) (count 1000) (stride 2) (scale 0.001) (offset 0.0))
```
Value = element_index * scale + offset.

### Expression VM (0x60-0x7F)

For complex expressions, a minimal stack-based VM executes per-element:

```lisp
; Spiral pattern: cos(t * 2π) * sqrt(t) where t = id/count
(fill-expr $d:0 (offset 0) (count 1000) (stride 2)
  (expr
    (push-id)           ; stack: [id]
    (push 1000.0)       ; stack: [id, 1000]
    (div)               ; stack: [t]
    (dup)               ; stack: [t, t]
    (push 6.283185)     ; stack: [t, t, 2π]
    (mul)               ; stack: [t, t*2π]
    (cos)               ; stack: [t, cos(t*2π)]
    (swap)              ; stack: [cos(t*2π), t]
    (sqrt)              ; stack: [cos(t*2π), sqrt(t)]
    (mul)               ; stack: [result]
    (store)))           ; output result
```

**Expression Bytecode (22 bytes):**
```
61                      ; PushElementId
60 00 00 7A 44          ; PushConst 1000.0
73                      ; Div
64                      ; Dup
60 DB 0F 49 40          ; PushConst 6.283185 (2π)
72                      ; Mul
79                      ; Cos
65                      ; Swap
7A                      ; Sqrt
72                      ; Mul
7F                      ; Store
```

### Complete Star Particles Example

**DSL Input:**
```pngine
#define NUM_STARS_PARTICLES="64*64"

#data initialStarsParticlesData {
  float32Array={
    numberOfElements=NUM_STARS_PARTICLES
    initEachElementWith=[
      "(random() * 20) - 10"   // pos.x
      "(random() * 20) - 10"   // pos.y
      "(random() * 20) - 10"   // pos.z
      "1.0"                    // pos.w
    ]
  }
}
```

**Compiled PBSF:**
```lisp
(data $d:0 f32 16384)  ; 4096 particles × 4 floats

; Position XYZ: random(-10, 10)
(fill-random $d:0 (offset 0) (count 4096) (stride 4) (seed 0) (min -10) (max 10))
(fill-random $d:0 (offset 1) (count 4096) (stride 4) (seed 1) (min -10) (max 10))
(fill-random $d:0 (offset 2) (count 4096) (stride 4) (seed 2) (min -10) (max 10))

; Position W: constant 1.0
(fill-const $d:0 (offset 3) (count 4096) (stride 4) (value 1.0))

; Create buffer and initialize
(buffer $buf:0 (size 65536) (usage vertex storage copy-dst))
(init-buffer $buf:0 $d:0)
```

### Determinism Guarantee

All runtime generation is deterministic:

1. **Seeded PRNG**: Each FillRandom uses explicit seed
2. **Reproducible**: Same bytecode → same output
3. **Cross-platform**: IEEE 754 float operations

Seed derivation: `hash(data_name, field_index, expression_index)`

---

## miniray Integration

PNGine uses [miniray](https://github.com/HugoDaniel/miniray) for WGSL minification.

### PNGine Preset

```bash
miniray --config configs/pngine.json shader.wgsl
```

Config preserves:
- Uniform struct types (`preserveUniformStructTypes: true`)
- `PngineInputs`, `TimeInputs`, `CanvasInputs` structs
- Entry point names

### Size Reduction

| Mode | Reduction |
|------|-----------|
| Whitespace only | 25-35% |
| Full (default) | 55-65% |
| Full + mangle bindings | 60-70% |

### Combined Pipeline

```
Original shader:          100KB
After miniray:             40KB (60% reduction)
After CreateShaderConcat:  24KB (39% dedup reduction)
Final embedded:            24KB (76% total)
```

### Source Maps

For debugging minified shaders:
```javascript
const result = minify(source, { sourceMap: true, sourceMapSources: true });
// Translate WebGPU errors back to original source
```

---

## Real-World Pattern Analysis

### The Bind Group Creation Pattern (8 Instructions → 1)

**Current (verbose):**
```javascript
["set", "tmp.descriptor", "$", "actions", "fromJSON", "{...}"]
["set", "tmp.cloned_descriptor", "$", "actions", "clone", "$", "tmp.descriptor"]
["set", "tmp.cloned_descriptor.layout", "$", "renderPipelines.X", "getBindGroupLayout", "0"]
["set", "tmp.current_entry", "$", "eval", "$", "actions", "at", "$tmp.cloned_descriptor", "entries", 0]
["set", "tmp.current_entry.resource.buffer", "$", "buffers.Y"]
["set", "tmp.cloned_descriptor.entries", 0, "$", "tmp.current_entry"]
// ... repeat for each binding
["set", "bindGroups.X", "$", "device", "createBindGroup", "$", "tmp.cloned_descriptor"]
```

**Bytecode (single instruction):**
```
CreateBindGroup {
  id: 0,
  layout_source: Pipeline(0),
  layout_index: 0,
  entries: [
    { binding: 0, buffer: 3 },
    { binding: 1, sampler: 0 },
  ]
}
```

### The Render Pass Pattern (12 Instructions → Linear Sequence)

**Current:**
```javascript
["set", "renderPass.drawSceneR", "$", "\\", "__isolate__", "encoder", [
  ["set", "tmp.current_renderPass", "$", "actions", "fromJSON", "{...}"],
  ["set", "tmp.current_gpuDescriptor", "$", "actions", "clone", "$", "tmp.current_renderPass"],
  ["set", "tmp.ca", "$", "actions", "at", "$tmp.current_gpuDescriptor", "colorAttachments", 0],
  ["set", "tmp.current_texture", "$", "textures", "renderTarget"],
  ["set", "tmp.ca.view", "$", "tmp.current_texture", "createView", ...],
  ["set", "tmp.pass", "$", "encoder", "beginRenderPass", "$", "tmp.current_gpuDescriptor"],
  ["tmp.pass", "setPipeline", "$renderPipelines.renderSceneR"],
  ["tmp.pass", "setBindGroup", 0, "$bindGroups.sceneRInputsBindGroup"],
  ["tmp.pass", "draw", 3],
  ["tmp.pass", "end"]
]]
```

**Bytecode:**
```
BeginRenderPass { color_attachment: Texture(0), load_op: Clear, store_op: Store }
SetPipeline { pipeline: 5 }
SetBindGroup { slot: 0, group: 2 }
Draw { vertices: 3, instances: 1 }
EndPass
```

### The Frame Pattern

**Current:**
```javascript
["set", "frame.sceneR", "$", "\\", "__isolate__", [
  ["set", "encoder", "$", "device", "createCommandEncoder"],
  ["queue.writePngineInputs"],
  ["queue.writeSceneRInputs"],
  ["renderPass.drawSceneR", "$encoder"],
  ["renderPass.postProcessCommonRenderPass", "$encoder"],
  ["device.queue", "submit", "$", "actions", "wrapArray", ["$encoder", "finish"]]
]]
```

**Bytecode:**
```
DefineFrame { id: 0, name_data: 12 }  // name in data section
  WriteBuffer { buffer: 0, data: 0 }  // PngineInputs
  WriteBuffer { buffer: 1, data: 1 }  // SceneRInputs
  ExecutePass { pass: 0 }             // drawSceneR
  ExecutePass { pass: 1 }             // postProcess
  Submit
EndFrame
```

---

## Handling Runtime Uniforms

### Compile-Time vs Runtime Resolution

**Compile-time (moved to bytecode):**
- Uniform buffer creation
- Bind group assignments
- Buffer-to-binding mapping

**Runtime (kept in executor):**
- `time`, `canvasW`, `canvasH` updates
- User input merging
- Dirty tracking for conditional uploads

### Uniform Metadata in Data Section

```zig
const UniformMetadata = struct {
    buffer_id: u16,
    byte_size: u16,
    fields: []FieldMeta,
};

const FieldMeta = struct {
    name_string_id: u16,
    offset: u16,
    field_type: FieldType,  // f32, vec2f, vec3f, vec4f, mat4f
};
```

### Runtime Builtin Updates

```zig
// Opcode: UpdateBuiltins (0xF0)
fn handleUpdateBuiltins(self: *Executor) void {
    for (self.builtin_uniforms) |uniform| {
        if (uniform.time_field_offset) |offset| {
            writeF32(&self.uniform_data[uniform.buffer_id], offset, self.time);
        }
        if (uniform.canvas_field_offset) |offset| {
            writeF32(&self.uniform_data[uniform.buffer_id], offset, self.canvas_width);
            writeF32(&self.uniform_data[uniform.buffer_id], offset + 4, self.canvas_height);
        }
        self.queue.writeBuffer(self.buffers[uniform.buffer_id], 0, self.uniform_data[uniform.buffer_id]);
    }
}
```

---

## Zig Executor Implementation

### Core Structure

```zig
pub const Executor = struct {
    // WebGPU handles (via JS imports)
    device: DeviceHandle,
    queue: QueueHandle,

    // Resource tables (indexed by ID)
    buffers: [MAX_BUFFERS]BufferHandle,
    textures: [MAX_TEXTURES]TextureHandle,
    samplers: [MAX_SAMPLERS]SamplerHandle,
    shader_modules: [MAX_SHADERS]ShaderHandle,
    render_pipelines: [MAX_PIPELINES]PipelineHandle,
    compute_pipelines: [MAX_PIPELINES]PipelineHandle,
    bind_groups: [MAX_BIND_GROUPS]BindGroupHandle,

    // Frame definitions (pre-parsed)
    frames: [MAX_FRAMES]FrameDef,
    passes: [MAX_PASSES]PassDef,

    // Runtime state
    ctx: Context,
    uniform_data: [MAX_BUFFERS][MAX_UNIFORM_SIZE]u8,

    // Data section
    data: []const DataEntry,
    strings: []const []const u8,

    const MAX_BUFFERS = 64;
    const MAX_TEXTURES = 32;
    const MAX_SAMPLERS = 16;
    const MAX_SHADERS = 32;
    const MAX_PIPELINES = 32;
    const MAX_BIND_GROUPS = 64;
    const MAX_FRAMES = 16;
    const MAX_PASSES = 32;
    const MAX_UNIFORM_SIZE = 256;

    pub fn executeFrame(self: *Executor, frame_id: u32, time: f32) void {
        self.ctx.time = time;
        self.updateBuiltins();

        const frame = &self.frames[frame_id];
        self.ctx.command_encoder = wgpu.createCommandEncoder(self.device);

        for (frame.passes) |pass_id| {
            self.executePass(pass_id);
        }

        wgpu.queueSubmit(self.queue, wgpu.finish(self.ctx.command_encoder));
    }

    fn executePass(self: *Executor, pass_id: u32) void {
        const pass = &self.passes[pass_id];
        var pc: u32 = pass.bytecode_offset;
        const end = pass.bytecode_offset + pass.bytecode_len;

        while (pc < end) {
            const opcode: OpCode = @enumFromInt(self.bytecode[pc]);
            pc += 1;

            switch (opcode) {
                .begin_render_pass => {
                    const texture_id = self.readVarint(&pc);
                    const view = wgpu.createView(self.textures[texture_id]);
                    self.ctx.render_pass = wgpu.beginRenderPass(self.ctx.command_encoder, view);
                },
                .set_pipeline => {
                    const pipeline_id = self.readVarint(&pc);
                    wgpu.setPipeline(self.ctx.render_pass, self.render_pipelines[pipeline_id]);
                },
                .set_bind_group => {
                    const slot = self.readVarint(&pc);
                    const group_id = self.readVarint(&pc);
                    wgpu.setBindGroup(self.ctx.render_pass, slot, self.bind_groups[group_id]);
                },
                .draw => {
                    const vertices = self.readVarint(&pc);
                    const instances = self.readVarint(&pc);
                    wgpu.draw(self.ctx.render_pass, vertices, instances);
                },
                .end_pass => {
                    wgpu.endPass(self.ctx.render_pass);
                    self.ctx.render_pass = null;
                },
                else => {},
            }
        }
    }
};
```

### Expected WASM Size

With aggressive optimization:

```toml
[profile.release]
opt-level = 'z'
lto = true
codegen-units = 1
panic = 'abort'
strip = true
```

Plus `wasm-opt -Oz`: **~25-35KB**

---

## WASM Interface

### Exports

```zig
export fn init() void;
export fn loadBytecode(ptr: [*]const u8, len: usize) i32;
export fn executeFrame(frame_id: u32, time: f32) void;
export fn getShaderInfo() [*]const u8;  // Returns JSON pointer
export fn getShaderInfoLen() usize;
export fn malloc(size: usize) ?[*]u8;
export fn free(ptr: ?[*]u8) void;
```

### Imports

```zig
// Logging
pub extern fn wasm_log_write(ptr: [*]const u8, len: usize) void;
pub extern fn wasm_log_flush() void;

// Time
pub extern fn performanceNow() f32;

// WebGPU (handle-based)
pub extern fn wgpu_createBuffer(size: u32, usage: u32) u32;
pub extern fn wgpu_createTexture(width: u32, height: u32, format: u32, usage: u32) u32;
pub extern fn wgpu_createShaderModule(code_ptr: [*]const u8, code_len: usize) u32;
pub extern fn wgpu_createRenderPipeline(desc_ptr: [*]const u8, desc_len: usize) u32;
pub extern fn wgpu_createBindGroup(layout: u32, entries_ptr: [*]const u8, entries_len: usize) u32;
pub extern fn wgpu_createCommandEncoder() u32;
pub extern fn wgpu_beginRenderPass(encoder: u32, desc_ptr: [*]const u8, desc_len: usize) u32;
pub extern fn wgpu_setPipeline(pass: u32, pipeline: u32) void;
pub extern fn wgpu_setBindGroup(pass: u32, slot: u32, group: u32) void;
pub extern fn wgpu_draw(pass: u32, vertices: u32, instances: u32) void;
pub extern fn wgpu_endPass(pass: u32) void;
pub extern fn wgpu_finish(encoder: u32) u32;
pub extern fn wgpu_queueSubmit(cmd_buffer: u32) void;
pub extern fn wgpu_writeBuffer(buffer: u32, offset: u32, data_ptr: [*]const u8, data_len: usize) void;
```

---

## Size Reduction Summary

| Component | Current | Bytecode |
|-----------|---------|----------|
| Demo file size | 1.7MB | ~50KB |
| Instruction count | 644 | ~200 opcodes |
| Avg per instruction | 2.6KB | ~50 bytes |
| Shader handling | Embedded JSON | Compressed data section |
| String paths | Repeated verbatim | String table + IDs |
| Interpreter size | 15KB JS | 25-35KB WASM |
| Parse overhead | JSON.parse | Zero (direct execution) |
| Platform support | JS only | JS, Swift, Kotlin, Rust |

The bytecode architecture transforms PNGine from a verbose, JS-centric system into a compact, portable, multi-platform format while maintaining full backward compatibility.

---

## Error Handling

From SHADER_ERROR_HANDLING.md:

### Error Types

```zig
const ShaderError = struct {
    shader_id: u32,
    line: u32,
    column: u32,
    message: []const u8,
    source_context: []const u8,
};

const PipelineError = struct {
    pipeline_id: u32,
    scope: []const u8,
    message: []const u8,
    error_type: []const u8,
};
```

### Error Modes

Configuration options:
- `error`: Throw immediately, halt execution
- `warning`: Log and continue
- `collect`: Accumulate errors, report via `info()`
- `ignore`: Silent failure

### Pretty-Printed Messages

```
Shader Compilation Error in shader $shd:3:
  Line 42, Column 15: expected ';' after statement

  40 |     let x = foo;
  41 |     let y = bar
  42 |     let z = baz;
                ^
```

---

## Migration Strategy

### Version Detection

```javascript
// In viewer.ts
const { version, instructions, interpreter } = JSON.parse(content);

if (version === 2) {
    // Load WASM executor
    const executor = await loadWasmExecutor();
    executor.load(bytecode, dataSection);
    return { draw: (t, f) => executor.executeFrame(f, t) };
} else {
    // Legacy JS interpreter
    return legacyInterpreter(instructions);
}
```

### Backward Compatibility

| PNG Version | Contents | Executor |
|-------------|----------|----------|
| v1 (current) | JSON + JS interpreter | JavaScript Worker |
| v2 (new) | Bytecode + WASM executor | Zig/WASM |

Old PNGs continue working. New compiler produces smaller v2 PNGs.
