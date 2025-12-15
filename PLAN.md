# PNGine Zig Implementation Plan

## Executive Summary

Recreate pngine in Zig with a register-based bytecode interpreter that compiles to WASM. The interpreter is bundled inside PNG files and executed in a WebWorker. This approach replaces the JSON array-based instruction format with a compact binary format (PNGB), with an S-expression text format (PBSF) for debugging and LLM generation.

**Target metrics:**
- Bytecode parsing: <1ms
- Frame execution overhead: <0.1ms
- Bytecode size: 30x smaller than JSON
- WASM interpreter: <35KB

---

## Architecture Overview

### Old Architecture (TypeScript)

```
.pngine.wgsl → DSL Parser (ast.ts) → Macro Parsers → JSON Instructions → JS Interpreter
```

- Instructions are JSON arrays: `["set", "buffers.vbo", "$", "device", "createBuffer", ...]`
- Pipeline operator `$` chains operations right-to-left
- ~15KB minified JS interpreter embedded in each PNG
- Keywords: `set`, `each`, `\` (lambda), `eval`

### New Architecture (Zig)

```
.pngine.wgsl ──► .pbsf (S-Expression) ◄────► .pngb (Binary)
                 (Human/LLM readable)        (Size-optimized)
                                             (Embedded in PNG)
```

**Dual Format System** (like WebAssembly's .wat/.wasm):

| Format | Purpose | Use Case |
|--------|---------|----------|
| PBSF | Human/LLM readable, debugging, diffs | Development, LLM generation |
| PNGB | Size-optimized, direct execution | PNG embedding, runtime |

---

## Core Design Decisions

### Register-Based Architecture (Not Stack-Based)

PNGine dispatches GPU API calls, not arithmetic. Resource tables ARE registers:

```
buffers[0]    → buffer register 0
pipelines[3]  → pipeline register 3
bindGroups[2] → bind group register 2
```

**Why register-based wins for GPU dispatch:**
- Explicit argument mapping: `CreateBuffer r0, 1024, 32`
- Natural fit for descriptor fields
- Same pattern across all platforms (Rust/Swift/Kotlin)

### Context Slots

Only ~4 context slots needed, not 32 general registers:

```zig
const Context = struct {
    command_encoder: ?CommandEncoder,
    render_pass: ?RenderPassEncoder,
    compute_pass: ?ComputePassEncoder,
    frame_index: u32,  // For ping-pong selection
};
```

---

## PNGB Binary Format

### File Structure (16 bytes header)

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
│   instructions: [u8 | varint]       │
│   (variable-length encoded)         │
└─────────────────────────────────────┘
```

### Variable-Length Integer Encoding (LEB128-style)

| Value Range | Encoding | Bytes |
|-------------|----------|-------|
| 0-127 | `0xxxxxxx` | 1 |
| 128-16383 | `10xxxxxx xxxxxxxx` | 2 |
| 16384+ | `11xxxxxx xxxxxxxx xxxxxxxx xxxxxxxx` | 4 |

Most resource IDs fit in 1 byte. Buffer sizes need 4 bytes.

---

## PBSF Text Format (S-Expression)

Human/LLM readable format for development:

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

**Syntax conventions:**
- `$type:id` - Resource references (buffer, shader, pipeline, etc.)
- `$d:id` - Data section references
- `@swapchain` - Special runtime values
- Named parameters in parentheses

---

## Opcode Definitions

```zig
const OpCode = enum(u8) {
    // Resource Creation (0x00-0x1F)
    create_buffer = 0x01,         // id, size, usage
    create_texture = 0x02,        // id, width, height, format, usage
    create_sampler = 0x03,        // id, descriptor_data_id
    create_shader_module = 0x04,  // id, code_data_id
    create_shader_concat = 0x05,  // id, count, data_ids... (WGSL composition)
    create_bind_group_layout = 0x06,
    create_pipeline_layout = 0x07,
    create_render_pipeline = 0x08,
    create_compute_pipeline = 0x09,
    create_bind_group = 0x0A,     // id, layout_pipeline, layout_index, entries...

    // Pass Operations (0x10-0x1F)
    begin_render_pass = 0x10,     // color_texture, load_op, store_op
    begin_compute_pass = 0x11,
    set_pipeline = 0x12,          // pipeline_id
    set_bind_group = 0x13,        // slot, group_id
    set_vertex_buffer = 0x14,     // slot, buffer_id
    set_index_buffer = 0x15,      // buffer_id, format
    draw = 0x16,                  // vertex_count, instance_count
    draw_indexed = 0x17,          // index_count, instance_count
    dispatch = 0x18,              // x, y, z
    end_pass = 0x19,

    // Queue Operations (0x20-0x2F)
    write_buffer = 0x20,          // buffer_id, offset, data_id
    write_uniform = 0x21,         // buffer_id, uniform_id (runtime-resolved)
    copy_buffer_to_buffer = 0x22,
    copy_texture_to_texture = 0x23,
    submit = 0x24,

    // Frame Control (0x30-0x3F)
    define_frame = 0x30,          // frame_id, name_string_id
    end_frame = 0x31,
    exec_pass = 0x32,             // pass_id
    define_pass = 0x33,           // pass_id, type, descriptor_data_id
    end_pass_def = 0x34,

    // Pool Operations (0x40-0x4F)
    select_from_pool = 0x40,      // dest_slot, pool_id, offset

    // Data Array Operations (0x50-0x5F) - Runtime Data Generation
    create_typed_array = 0x50,    // type, id, element_count
    fill_constant = 0x51,         // arr, offset, count, stride, value
    fill_random = 0x52,           // arr, offset, count, stride, seed, min, max
    fill_linear = 0x53,           // arr, offset, count, stride, start, step
    fill_element_index = 0x54,    // arr, offset, count, stride, scale, offset
    fill_expression = 0x55,       // arr, offset, count, stride, expr_len, expr_bytecode
    init_buffer_from_array = 0x58, // buffer_id, array_id
    write_array_to_buffer = 0x59, // buffer_id, buf_offset, arr_id, arr_offset, size

    // Expression VM (0x60-0x7F) - Per-element Math
    expr_push_const = 0x60,       // Push f32 constant
    expr_push_element_id = 0x61,  // Push current element index
    expr_push_element_count = 0x62, // Push total element count
    expr_push_random = 0x63,      // Push seeded random [0,1)
    expr_dup = 0x64,              // Duplicate top
    expr_swap = 0x65,             // Swap top two
    expr_pop = 0x66,              // Discard top
    expr_add = 0x70,              // a b → (a+b)
    expr_sub = 0x71,              // a b → (a-b)
    expr_mul = 0x72,              // a b → (a*b)
    expr_div = 0x73,              // a b → (a/b)
    expr_mod = 0x74,              // a b → (a%b)
    expr_min = 0x75,              // a b → min(a,b)
    expr_max = 0x76,              // a b → max(a,b)
    expr_sin = 0x78,              // a → sin(a)
    expr_cos = 0x79,              // a → cos(a)
    expr_sqrt = 0x7A,             // a → sqrt(a)
    expr_abs = 0x7B,              // a → abs(a)
    expr_floor = 0x7C,            // a → floor(a)
    expr_fract = 0x7D,            // a → fract(a)
    expr_store = 0x7F,            // Store result, end expression

    // Runtime (0xF0-0xFF)
    update_builtins = 0xF0,       // Updates time, canvas dimensions
    nop = 0xFE,
    halt = 0xFF,
};
```

### CreateShaderConcat (0x05) - Runtime WGSL Composition

From RUNTIME_WGSL_COMPOSITION.md - enables shader deduplication:

```
05 <shader_id> <count> <data_ids...>
```

Concatenates WGSL fragments from data section at runtime:
- Common preambles shared across shaders
- Expected 39% reduction in shader code size

Example:
```
(shader-concat $shd:3 $d:0 $d:1 $d:4)  ; Concatenate data entries 0, 1, 4
```

---

## Runtime Data Generation (0x50-0x7F)

From DATA_RUNTIME_GENERATION.md - data generation moves from compile-time to runtime for massive size savings.

### Why Runtime Generation?

| Scenario | Compile-Time (embedded) | Runtime Generation |
|----------|------------------------|-------------------|
| 4K particles (128KB) | 109KB compressed | ~100 bytes bytecode |
| 64K noise texture (256KB) | 200KB compressed | ~20 bytes bytecode |
| 1K spiral points (8KB) | 6KB compressed | ~60 bytes bytecode |

**Threshold**: Use runtime generation for arrays > 1KB.

### Fill Operations

```lisp
; Star particles example
(data $d:0 f32 32768)  ; Allocate 32768 floats

; Position XYZ: random(-10, 10)
(fill-random $d:0 (offset 0) (count 4096) (stride 8) (seed 0) (min -10) (max 10))
(fill-random $d:0 (offset 1) (count 4096) (stride 8) (seed 1) (min -10) (max 10))
(fill-random $d:0 (offset 2) (count 4096) (stride 8) (seed 2) (min -10) (max 10))

; Position W: constant 1.0
(fill-const $d:0 (offset 3) (count 4096) (stride 8) (value 1.0))

; Initialize GPU buffer from array
(init-buffer $buf:0 $d:0)
```

### Expression VM

For complex expressions that can't be reduced to simple patterns:

```lisp
; Spiral: cos(t * 2π) * sqrt(t)
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

### Determinism

All runtime generation is deterministic via seeded PRNG:
- Each `fill-random` uses explicit seed
- Seed derived from: `hash(data_name, field_index, expression_index)`
- Same bytecode → identical output across platforms

---

## miniray Integration

PNGine uses the [miniray](https://github.com/HugoDaniel/miniray) WGSL minifier for shader optimization.

### PNGine Preset

```bash
miniray --config configs/pngine.json shader.wgsl
```

Preserves:
- Uniform struct types (`preserveUniformStructTypes: true`)
- `PngineInputs`, `TimeInputs`, `CanvasInputs` structs
- Entry point names

### Integration Points

1. **Compile-time**: DSL compiler runs miniray on extracted WGSL before embedding
2. **CreateShaderConcat**: Fragments are minified individually, then concatenated

### Expected Savings

| Mode | Reduction |
|------|-----------|
| Whitespace only | 25-35% |
| Full (default) | 55-65% |
| Full + mangle bindings | 60-70% |

### Combined with CreateShaderConcat

```
Original shader code:     100KB
After miniray:             40KB (60% reduction)
After fragment sharing:    24KB (39% additional reduction from dedup)
Final embedded size:       24KB (76% total reduction)
```

### Source Maps for Debugging

```javascript
const result = minify(source, {
  sourceMap: true,
  sourceMapSources: true  // Embed original source
});
// Use source map to translate WebGPU compilation errors back to original
```

---

## Module Structure

```
src/
├── main.zig              # Entry point, WASM exports
├── bytecode/
│   ├── reader.zig        # PNGB binary parser
│   ├── varint.zig        # LEB128 encoding/decoding
│   └── header.zig        # Header parsing
├── executor/
│   ├── core.zig          # Main dispatch loop
│   ├── resources.zig     # Resource table management
│   ├── context.zig       # Encoder/pass context
│   ├── uniforms.zig      # Uniform system, dirty tracking
│   └── builtins.zig      # time, canvasW, canvasH
├── datagen/
│   ├── arrays.zig        # Typed array allocation
│   ├── fill.zig          # Fill operations (const, random, linear, index)
│   ├── expression.zig    # Expression VM (0x60-0x7F opcodes)
│   └── rng.zig           # Seeded PRNG (deterministic)
├── pbsf/
│   ├── tokenizer.zig     # S-expression tokenizer
│   ├── parser.zig        # S-expression parser
│   └── assembler.zig     # PBSF → PNGB conversion
├── wasm/
│   ├── exports.zig       # WASM exported functions
│   ├── imports.zig       # JS function imports
│   └── memory.zig        # malloc/free for JS interop
└── test/
    ├── mock_webgpu.zig   # WebGPU mock for testing
    ├── varint_test.zig
    ├── reader_test.zig
    ├── executor_test.zig
    ├── datagen_test.zig  # Data generation tests
    ├── expression_test.zig # Expression VM tests
    └── e2e_test.zig
```

---

## TDD Implementation Phases

### Phase 1: S-Expression Parser Foundation

**Tests:**
1. Empty input → empty AST
2. Single atom → atom node
3. Nested list → tree structure
4. String literals with escapes
5. Numbers (int, float, hex)
6. Comments (`;` to EOL)
7. Error recovery (unmatched parens)

```zig
test "parse simple list" {
    const input = "(buffer $buf:0 (size 1024))";
    const ast = try SExprParser.parse(testing.allocator, input);
    defer ast.deinit();

    try testing.expectEqual(ast.root.children.len, 3);
    try testing.expectEqualStrings(ast.root.children[0].atom, "buffer");
}
```

### Phase 2: Binary Format Reader

**Tests:**
1. Header magic validation
2. Version check
3. String table decoding
4. Data section access
5. Varint decoding (all size variants)
6. Malformed input handling

```zig
test "varint encoding roundtrip" {
    var buf: [5]u8 = undefined;

    // Single byte
    const len1 = writeVarint(&buf, 42);
    try testing.expectEqual(len1, 1);
    try testing.expectEqual(readVarint(buf[0..len1]), 42);

    // Two bytes
    const len2 = writeVarint(&buf, 1000);
    try testing.expectEqual(len2, 2);
    try testing.expectEqual(readVarint(buf[0..len2]), 1000);
}
```

### Phase 3: Assembler/Disassembler

**Tests:**
1. PBSF → PNGB conversion
2. PNGB → PBSF conversion
3. Roundtrip identity
4. String table deduplication
5. Data section reference resolution

### Phase 4: Executor Core (Mock WebGPU)

**Tests:**
1. CreateBuffer stores in resource table
2. CreateShaderModule with data section reference
3. CreateShaderConcat concatenates fragments
4. CreateRenderPipeline with shader references
5. CreateBindGroup with layout from pipeline

```zig
test "CreateBuffer opcode" {
    var mock = MockWebGPU.init(testing.allocator);
    defer mock.deinit();

    var executor = Executor.init(&mock);

    // Bytecode: CreateBuffer id:0 size:1024 usage:0x48
    const bytecode = [_]u8{ 0x01, 0x00, 0x04, 0x00, 0x48 };
    try executor.execute(&bytecode);

    try testing.expect(mock.buffers_created == 1);
    try testing.expectEqual(mock.last_buffer_size, 1024);
}
```

### Phase 5: Resource Creation Opcodes

Each opcode tested:
- CreateBuffer
- CreateTexture
- CreateSampler
- CreateShaderModule
- CreateShaderConcat
- CreateBindGroupLayout
- CreatePipelineLayout
- CreateRenderPipeline
- CreateComputePipeline
- CreateBindGroup

### Phase 6: Pass/Draw Opcodes

**Tests:**
1. BeginRenderPass creates encoder + pass
2. SetPipeline binds pipeline to pass
3. SetBindGroup binds at correct slot
4. Draw issues correct vertex/instance counts
5. EndPass finalizes render pass
6. Nested pass prevention

### Phase 7: Queue/Buffer Opcodes

**Tests:**
1. WriteBuffer with static data
2. WriteUniform with runtime resolution
3. CopyBufferToBuffer
4. CopyTextureToTexture
5. Submit queues command buffer

### Phase 8: Frame Control

**Tests:**
1. DefineFrame creates frame entry
2. ExecPass executes pass bytecode
3. EndFrame finalizes frame
4. Frame lookup by name
5. Multiple frames

### Phase 9: Runtime Data Generation

From DATA_RUNTIME_GENERATION.md - generate procedural data at runtime.

**Phase 9a: Simple Patterns (80% of use cases)**
- CreateTypedArray (0x50) - f32, u32, i32, f16
- FillConstant (0x51) - fill with single value
- FillRandom (0x52) - seeded random in range

```zig
test "FillRandom produces deterministic output" {
    var arr = try TypedArray.init(testing.allocator, .f32, 1000);
    defer arr.deinit();

    fillRandom(&arr, .{ .offset = 0, .count = 1000, .stride = 1, .seed = 42, .min = -10, .max = 10 });

    // Same seed → same output
    var arr2 = try TypedArray.init(testing.allocator, .f32, 1000);
    defer arr2.deinit();
    fillRandom(&arr2, .{ .offset = 0, .count = 1000, .stride = 1, .seed = 42, .min = -10, .max = 10 });

    try testing.expectEqualSlices(f32, arr.asF32(), arr2.asF32());
}
```

**Phase 9b: Extended Patterns (95% of use cases)**
- FillLinear (0x53) - arithmetic sequence
- FillElementIndex (0x54) - based on index

**Phase 9c: Expression VM (100% coverage)**
- FillExpression (0x55) - arbitrary math per element
- Expression opcodes (0x60-0x7F)

```zig
test "Expression VM: spiral pattern" {
    // cos(t * 2π) * sqrt(t) where t = id/count
    const expr = [_]u8{
        0x61,                   // PushElementId
        0x60, 0x00, 0x00, 0x7A, 0x44, // PushConst 1000.0
        0x73,                   // Div
        0x64,                   // Dup
        0x60, 0xDB, 0x0F, 0x49, 0x40, // PushConst 2π
        0x72,                   // Mul
        0x79,                   // Cos
        0x65,                   // Swap
        0x7A,                   // Sqrt
        0x72,                   // Mul
        0x7F,                   // Store
    };

    const result = executeExpression(&expr, 500, 1000, &rng);
    // t = 0.5, cos(π) * sqrt(0.5) = -1 * 0.707... ≈ -0.707
    try testing.expectApproxEqAbs(@as(f32, -0.707), result, 0.01);
}
```

### Phase 10: Uniform System

**Tests:**
1. Dirty tracking per-buffer
2. Conditional upload (skip if clean)
3. Built-in field detection (time, canvas)
4. User input merging
5. Byte layout validation

### Phase 11: Pool/Ping-Pong

**Tests:**
1. SelectFromPool with index
2. Frame-based index toggling
3. Texture pool selection
4. Buffer pool selection

### Phase 12: Compiler Integration

**Tests:**
1. Macro expansion to bytecode
2. #buffer → CreateBuffer
3. #texture → CreateTexture
4. #renderPipeline → CreateRenderPipeline
5. #frame → DefineFrame + body

### Phase 13: End-to-End Tests

**Tests:**
1. Minimal triangle scene
2. Uniform buffer updates
3. Multi-pass rendering
4. Compute dispatch
5. Real demo scene (inercia2025 equivalent)

### Phase 14: Error Handling

From SHADER_ERROR_HANDLING.md:
- ShaderCompilationError with source context
- PipelineCreationError with scope info
- Configuration: error/warning/collect/ignore modes
- Pretty-printed messages

### Phase 15: Performance Benchmarks

**Metrics:**
1. Bytecode parse time (<1ms)
2. Frame execution overhead (<0.1ms)
3. Memory usage (static allocation)
4. WASM binary size (<35KB)

---

## Test Coverage Plan (Porting from old_pngine)

The old_pngine test suite contains comprehensive tests that must be ported to Zig. Tests are organized by category with equivalent Zig implementations.

### Category 1: Macro Parser Tests

Port preprocessor tests to validate DSL → AST → Bytecode conversion.

| old_pngine Test | Zig Equivalent | Priority |
|-----------------|----------------|----------|
| `preprocessor-parseBuffer.test.ts` | `test/parser/buffer_test.zig` | High |
| `preprocessor-parseData.test.ts` | `test/parser/data_test.zig` | High |
| `preprocessor-parseFrame.test.ts` | `test/parser/frame_test.zig` | High |
| `preprocessor-parseRenderPipeline.test.ts` | `test/parser/render_pipeline_test.zig` | High |
| `preprocessor-parseComputePipeline.test.ts` | `test/parser/compute_pipeline_test.zig` | Medium |
| `preprocessor-parseBindGroup.test.ts` | `test/parser/bind_group_test.zig` | High |
| `preprocessor-parseTexture.test.ts` | `test/parser/texture_test.zig` | High |
| `preprocessor-parseSampler.test.ts` | `test/parser/sampler_test.zig` | Medium |
| `preprocessor-parseQueue.test.ts` | `test/parser/queue_test.zig` | High |
| `preprocessor-parseDefine.test.ts` | `test/parser/define_test.zig` | High |
| `preprocessor-parseShaderModule.test.ts` | `test/parser/shader_module_test.zig` | High |
| `preprocessor-parseNum.test.ts` | `test/parser/num_expr_test.zig` | Medium |
| `preprocessor-removeComments.test.ts` | `test/parser/comments_test.zig` | Low |
| `preprocessor-parseRenderAndComputePass.test.ts` | `test/parser/pass_test.zig` | High |
| `preprocessor-parseBindGroupLayout.test.ts` | `test/parser/bind_group_layout_test.zig` | Medium |
| `preprocessor-parsePipelineLayout.test.ts` | `test/parser/pipeline_layout_test.zig` | Medium |
| `preprocessor-parseLabels.test.ts` | `test/parser/labels_test.zig` | Low |
| `preprocessor-parseQuerySet.test.ts` | `test/parser/query_set_test.zig` | Low |
| `preprocessor-parseImageBitmap.test.ts` | `test/parser/image_bitmap_test.zig` | Medium |
| `preprocessor-parseVideoAsset.test.ts` | `test/parser/video_asset_test.zig` | Medium |
| `preprocessor-parseWasmCall.test.ts` | `test/parser/wasm_call_test.zig` | Medium |
| `preprocessor-resolveImports.test.ts` | `test/parser/imports_test.zig` | Medium |

**Key test cases from parseBuffer:**
```zig
test "parse simple buffer" {
    const input =
        \\#buffer spriteVertexBuffer {
        \\    size=1024
        \\    usage=[VERTEX]
        \\    mappedAtCreation=someDataArray
        \\}
    ;
    const result = try parser.parseBuffer(input);
    try testing.expectEqual(result.size, 1024);
    try testing.expectEqual(result.usage, .vertex);
}

test "buffer size from data array reference" {
    // size=vertexBufferData → resolves to data array byteLength
}

test "buffer pool attribute" {
    // pool=2 → creates ping-pong buffer pool
}
```

**Key test cases from parseFrame:**
```zig
test "parse frame with before/after" {
    const input =
        \\#frame boids {
        \\    before=[updateSimParams]
        \\    perform=[computeBoidsPass drawBoidsPass]
        \\    after=[cleanup]
        \\}
    ;
    const result = try parser.parseFrame(input);
    try testing.expectEqualStrings(result.name, "boids");
    try testing.expectEqual(result.before.len, 1);
    try testing.expectEqual(result.perform.len, 2);
}

test "frame validation: non-existent pass throws" {
    // perform=[nonExistentPass] → error with available passes
}
```

**Key test cases from parseRenderPipeline:**
```zig
test "parse vertex buffers" {
    // buffers=[{arrayStride=100 attributes=[...]}]
}

test "parse fragment blend" {
    // blend={alpha={operation=subtract} color={...}}
}

test "parse depthStencil" {
    // depthStencil={format=depth32float depthWriteEnabled=true ...}
}

test "parse multisample" {
    // multisample={count=4 mask=0xFFFFFFFF}
}
```

### Category 2: WGSL Parser Tests

Port WGSL struct parsing for uniform buffer layout detection.

| old_pngine Test | Zig Equivalent | Priority |
|-----------------|----------------|----------|
| `wgslStruct.test.ts` | `test/wgsl/struct_test.zig` | High |
| `wgslData.test.ts` | `test/wgsl/data_test.zig` | High |
| `dataFromStruct.test.ts` | `test/wgsl/views_test.zig` | High |

**Key test cases:**
```zig
test "parse simple uniform struct" {
    const wgsl =
        \\struct Custom {
        \\  focalLength: u32,
        \\  cameraDistance: i32,
        \\  particleRadius: f32,
        \\};
        \\@group(0) @binding(0) var<uniform> custom: Custom;
    ;
    const result = try parseWGSLUniforms(wgsl);
    try testing.expectEqual(result.uniforms.get("custom").?.group, 0);
    try testing.expectEqual(result.uniforms.get("custom").?.binding, 0);
}

test "parse nested struct" {
    // struct Z { ... }; struct MyUniform { z: Z, ... };
}

test "parse array in struct" {
    // particles: array<vec3<f32>,10>
}

test "parse array of nested structs" {
    // array<ParticleElement, 10> where ParticleElement has nested data
}

test "parse struct with comments" {
    // Handle // comments in middle of struct definition
}

test "parse vec types" {
    // vec2f, vec3<f32>, vec4<u32>
}
```

### Category 3: Interpreter Tests

Port manifest interpreter tests for instruction execution semantics.

| old_pngine Test | Zig Equivalent | Priority |
|-----------------|----------------|----------|
| `compiler-interpreter.test.ts` | `test/executor/interpreter_test.zig` | Critical |

**Key test cases (these define the bytecode semantics):**
```zig
test "set instruction creates resource" {
    // ["set", "buffers.vbo", ...] → CreateBuffer opcode
}

test "$ applies nested instructions" {
    // ["set", "newThing", "$", "something", "get", "yay"]
    // → Pipeline operator right-to-left evaluation
}

test "$varname shorthand" {
    // "$something.yay" → equivalent to ["$", "something", "get", "yay"]
}

test "each iterates with index" {
    // ["each", "array", "\", "elem", "i", [...]]
}

test "lambda creates callable function" {
    // ["someFunctions", "set", "creator", "$", "\", "name", [...]]
}

test "eval interprets object attributes" {
    // Recursive evaluation of $-prefixed values in objects
}

test "eval with math expressions" {
    // "eval $ actions parseNum 2 12 sin(123) $something"
}
```

### Category 4: Validation Tests

Port validation tests for compile-time error detection.

| old_pngine Test | Zig Equivalent | Priority |
|-----------------|----------------|----------|
| `compiler-validation.test.ts` | `test/compiler/validation_test.zig` | High |

**Key test cases:**
```zig
test "error: pipeline references non-existent shader module" {
    // vertex={ module=nonExistent } → error with available modules list
}

test "error: queue references non-existent uniform" {
    // data="$uniforms.wrongModule.inputs.data" → error
}

test "error: frame references non-existent pass" {
    // perform=[nonExistentPass] → error
}

test "error: frame references non-existent queue in before" {
    // before=[invalidQueue] → error
}

test "passes validation when all references exist" {
    // Complete valid scene compiles without error
}
```

### Category 5: Shader Example Tests

Port shader examples as integration test fixtures.

| Shader | Complexity | Features Tested |
|--------|------------|-----------------|
| `simpleTriangle.shader.ts` | Minimal | Basic render pipeline, vertex shader |
| `simpleTriangleMSAA.shader.ts` | Low | MSAA multisampling |
| `movingTriangle.shader.ts` | Low | Uniforms (time), animation |
| `rotatingCube.shader.ts` | Medium | 3D transforms, depth buffer |
| `rotatingTexturedCube.shader.ts` | Medium | Texture sampling, UVs |
| `boids.shader.ts` | High | Compute shader, ping-pong buffers, instancing, #data generation |
| `rotatingCubeWASM.shader.ts` | Medium | WASM data generation |
| `rotatingCubeWASMData.shader.ts` | Medium | WASM module calling |
| `rotatingTorus.shader.ts` | Medium | Complex geometry |
| `videoQuad.shader.ts` | Medium | External texture (video) |
| `audioExample.shader.ts` | Medium | Audio system integration |
| `keyboardInteractive.shader.ts` | Low | Keyboard input handling |
| `sceneSwitchingShader.ts` | Medium | Multiple frames, timeline |

**Zig test fixtures:**
```zig
// test/fixtures/simple_triangle.zig
pub const simple_triangle_pbsf =
    \\(module "simpleTriangle"
    \\  (render-pipeline $pipe:0
    \\    (vertex (entry "vertexMain"))
    \\    (fragment (entry "fragMain") (targets (format @preferredCanvasFormat))))
    \\  (pass $pass:0 "renderPipeline"
    \\    (render (color-attachments (attachment (view @swapchain)))))
    \\  (frame $frm:0 "simpleTriangle" (exec-pass $pass:0) (submit)))
;

// test/fixtures/boids.zig - Complex example with compute + data generation
pub const boids_pbsf =
    \\(module "boids"
    \\  (data $d:0 f32 8192)
    \\  (fill-expr $d:0 (offset 0) (count 2048) (stride 4)
    \\    (expr (push-id) (push 2048.0) (div) (push 6.283185) (mul) (cos)
    \\          (push-id) (push 2048.0) (div) (sqrt) (mul) (store)))
    \\  ; ... rest of boids scene
    \\)
;
```

### Category 6: Snapshot/E2E Tests

Port visual regression tests using image comparison.

| Test | Description | Tolerance |
|------|-------------|-----------|
| Simple Triangle | Red triangle on black | <0.01 |
| MSAA Triangle | Anti-aliased edges | <0.01 |
| Moving Triangle | Time-based position at t=200 | <0.01 |
| Rotating Cube | 3D depth at t=1 | 0 (exact) |
| Textured Cube | UV mapped texture | <0.1 |
| WASM Cube | WASM-generated transforms | 0 (exact) |
| Boids | Compute shader particle positions | <500 pixels |

**Zig E2E test pattern:**
```zig
test "e2e: simple triangle renders correctly" {
    const bytecode = try assembler.assemblePBSF(fixtures.simple_triangle_pbsf);
    var executor = try Executor.init(mock_webgpu);
    defer executor.deinit();

    try executor.loadBytecode(bytecode);
    try executor.executeFrame(0, 0.0);

    const pixels = try mock_webgpu.readPixels();
    const diff = imageCompare(pixels, "assets/simple-triangle-snapshot.png");
    try testing.expect(diff < 0.01);
}

test "e2e: boids compute shader" {
    // Verify compute pass updates particle positions deterministically
}
```

### Category 7: Format Tests

Port PNG and bytecode format tests.

| old_pngine Test | Zig Equivalent | Priority |
|-----------------|----------------|----------|
| `png.test.ts` | `test/format/png_test.zig` | High |

**Key test cases:**
```zig
test "PNGB header parsing" {
    const bytes = [_]u8{'P', 'N', 'G', 'B', ...};
    const header = try Header.parse(&bytes);
    try testing.expectEqualStrings(header.magic[0..4], "PNGB");
}

test "PBSF to PNGB roundtrip" {
    const pbsf = "(buffer $buf:0 (size 1024) (usage vertex))";
    const pngb = try assembler.assemble(pbsf);
    const back = try disassembler.disassemble(pngb);
    try testing.expectEqualStrings(pbsf, back);
}

test "string table deduplication" {
    // Repeated strings share same string ID
}

test "varint encoding roundtrip" {
    for ([_]u32{0, 127, 128, 16383, 16384, 0xFFFFFF}) |val| {
        var buf: [5]u8 = undefined;
        const len = writeVarint(&buf, val);
        const decoded = readVarint(buf[0..len]);
        try testing.expectEqual(val, decoded);
    }
}
```

### Category 8: ISA Generation Tests

Port instruction set architecture tests.

| old_pngine Test | Zig Equivalent | Priority |
|-----------------|----------------|----------|
| `isa.test.ts` | `test/compiler/isa_test.zig` | High |

**Key test cases:**
```zig
test "ISA: creates shader module" {
    const bytecode = try compile(simple_triangle_dsl);
    try testing.expect(containsOpcode(bytecode, .create_shader_module));
}

test "ISA: creates render pipeline" {
    const bytecode = try compile(simple_triangle_dsl);
    try testing.expect(containsOpcode(bytecode, .create_render_pipeline));
}

test "ISA: creates frame with pass execution" {
    const bytecode = try compile(simple_triangle_dsl);
    try testing.expect(containsOpcode(bytecode, .define_frame));
    try testing.expect(containsOpcode(bytecode, .exec_pass));
}
```

### Category 9: CLI/Minification Tests (JS-side)

These remain JavaScript tests since they test the Node.js CLI tool.

| old_pngine Test | Notes |
|-----------------|-------|
| `cli-bundle.test.ts` | Tests PNG bundling CLI |
| `cli-config.test.ts` | Tests config file loading |
| `cli-inspect-shader.test.ts` | Tests shader inspection |
| `minify.test.ts` | Tests miniray integration |
| `minify-compiler.test.ts` | Tests minification in compiler |
| `minify-cli.test.ts` | Tests minification CLI |
| `minify-e2e.test.ts` | E2E minification tests |
| `wgsl-source-map.test.ts` | Tests source map generation |

### Category 10: Descriptor Registry Tests

| old_pngine Test | Zig Equivalent | Priority |
|-----------------|----------------|----------|
| `descriptor-registry.test.ts` | `test/compiler/descriptor_registry_test.zig` | Medium |

### Test Matrix Summary

| Category | old_pngine Files | Test Cases | Zig Phase |
|----------|-----------------|------------|-----------|
| Macro Parser | 22 files | ~150 cases | Phase 1-3 |
| WGSL Parser | 3 files | ~25 cases | Phase 4 |
| Interpreter | 1 file | ~30 cases | Phase 4-8 |
| Validation | 1 file | ~10 cases | Phase 8 |
| Shader Examples | 13 files | 13 fixtures | Phase 13 |
| Snapshot/E2E | 1 file | ~15 cases | Phase 13 |
| Format | 1 file | ~10 cases | Phase 2 |
| ISA | 1 file | ~5 cases | Phase 12 |
| CLI/Minify | 7 files | JS-only | N/A |

**Total: ~260 test cases to port**

### Test Infrastructure

```zig
// test/mock_webgpu.zig
pub const MockWebGPU = struct {
    buffers_created: u32 = 0,
    textures_created: u32 = 0,
    pipelines_created: u32 = 0,
    shaders_created: u32 = 0,
    bind_groups_created: u32 = 0,

    last_buffer_size: u32 = 0,
    last_buffer_usage: u32 = 0,
    last_draw_vertices: u32 = 0,
    last_draw_instances: u32 = 0,
    last_dispatch_x: u32 = 0,

    // Capture all API calls for verification
    call_log: std.ArrayList(APICall),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockWebGPU {
        return .{
            .call_log = std.ArrayList(APICall).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn createBuffer(self: *MockWebGPU, size: u32, usage: u32) u32 {
        self.buffers_created += 1;
        self.last_buffer_size = size;
        self.last_buffer_usage = usage;
        try self.call_log.append(.{ .create_buffer = .{ .size = size, .usage = usage } });
        return self.buffers_created - 1;
    }

    pub fn draw(self: *MockWebGPU, vertices: u32, instances: u32) void {
        self.last_draw_vertices = vertices;
        self.last_draw_instances = instances;
        try self.call_log.append(.{ .draw = .{ .vertices = vertices, .instances = instances } });
    }
    // ... other WebGPU mock methods
};

// test/image_compare.zig
pub fn compare(actual: []const u8, width: u32, height: u32, expected_path: []const u8) f32 {
    // Load expected PNG, compute pixel difference percentage
    const expected = loadPNG(expected_path);
    var diff_count: u32 = 0;
    for (actual, expected.pixels) |a, e| {
        if (a != e) diff_count += 1;
    }
    return @as(f32, @floatFromInt(diff_count)) / @as(f32, @floatFromInt(actual.len));
}
```

### 100% Code Coverage Requirement

**Goal: Every line, branch, and function in the Zig codebase must be covered by tests.**

#### Coverage Tools

```bash
# Run tests with coverage using kcov (Linux) or llvm-cov
zig build test -Doptimize=Debug

# Generate coverage report
kcov --include-path=src/ coverage/ zig-out/bin/test

# Or use Zig's built-in coverage (Zig 0.12+)
zig build test -ftest-coverage
zig-cov merge -o coverage.json zig-cache/...
```

#### Coverage Targets by Module

| Module | Target | Strategy |
|--------|--------|----------|
| `bytecode/varint.zig` | 100% | Boundary values: 0, 127, 128, 16383, 16384, max |
| `bytecode/reader.zig` | 100% | Valid + malformed inputs, all error paths |
| `bytecode/header.zig` | 100% | Magic mismatch, version mismatch, truncated |
| `executor/core.zig` | 100% | Every opcode, invalid opcodes, resource limits |
| `executor/resources.zig` | 100% | Full tables, ID reuse, lookup failures |
| `executor/uniforms.zig` | 100% | Dirty tracking, all field types, nested structs |
| `datagen/fill.zig` | 100% | All fill patterns, edge counts, strides |
| `datagen/expression.zig` | 100% | Every expression opcode, stack overflow/underflow |
| `datagen/rng.zig` | 100% | Seed reproducibility, range boundaries |
| `pbsf/tokenizer.zig` | 100% | All token types, malformed input, EOF handling |
| `pbsf/parser.zig` | 100% | All node types, nesting limits, error recovery |
| `pbsf/assembler.zig` | 100% | All PBSF constructs → PNGB |
| `wasm/exports.zig` | 100% | All exported functions, null/invalid args |
| `wasm/memory.zig` | 100% | malloc/free, alignment, OOM |

#### Coverage Enforcement

```zig
// build.zig - Fail CI if coverage drops below 100%
const coverage_step = b.step("coverage", "Run tests with coverage");

const coverage_check = b.addSystemCommand(&.{
    "sh", "-c",
    \\kcov --include-path=src/ coverage/ zig-out/bin/test && \
    \\coverage=$(jq '.percent_covered' coverage/zig-out/bin/test/coverage.json) && \
    \\if [ "$coverage" != "100.0" ]; then \
    \\  echo "Coverage is $coverage%, required 100%"; \
    \\  exit 1; \
    \\fi
});
coverage_check.step.dependOn(&run_tests.step);
coverage_step.dependOn(&coverage_check.step);
```

#### Branch Coverage Strategy

Every `if`, `switch`, and `else` branch must be exercised:

```zig
// Example: varint.zig - all branches covered
pub fn readVarint(bytes: []const u8) !struct { value: u32, len: u8 } {
    if (bytes.len == 0) return error.UnexpectedEof;  // Test: empty slice

    const first = bytes[0];
    if (first & 0x80 == 0) {                          // Test: 0-127
        return .{ .value = first, .len = 1 };
    } else if (first & 0xC0 == 0x80) {                // Test: 128-16383
        if (bytes.len < 2) return error.UnexpectedEof; // Test: truncated 2-byte
        return .{ .value = ..., .len = 2 };
    } else {                                          // Test: 16384+
        if (bytes.len < 4) return error.UnexpectedEof; // Test: truncated 4-byte
        return .{ .value = ..., .len = 4 };
    }
}

test "varint: all branches" {
    // Branch 1: empty input
    try testing.expectError(error.UnexpectedEof, readVarint(&[_]u8{}));

    // Branch 2: single byte (0-127)
    try testing.expectEqual(readVarint(&[_]u8{0}).?.value, 0);
    try testing.expectEqual(readVarint(&[_]u8{127}).?.value, 127);

    // Branch 3: two bytes (128-16383)
    try testing.expectEqual(readVarint(&[_]u8{0x80, 0x01}).?.value, 128);
    try testing.expectError(error.UnexpectedEof, readVarint(&[_]u8{0x80})); // truncated

    // Branch 4: four bytes (16384+)
    try testing.expectEqual(readVarint(&[_]u8{0xC0, 0x00, 0x40, 0x00}).?.value, 16384);
    try testing.expectError(error.UnexpectedEof, readVarint(&[_]u8{0xC0, 0x00})); // truncated
}
```

#### Error Path Coverage

Every `error` return must be tested:

```zig
// Define all possible errors
pub const ReaderError = error{
    InvalidMagic,
    UnsupportedVersion,
    UnexpectedEof,
    InvalidStringId,
    InvalidDataId,
    InvalidOpcode,
    ResourceLimitExceeded,
    StackOverflow,
    StackUnderflow,
    DivisionByZero,
};

// Test file must trigger each error
test "reader: InvalidMagic" {
    const bad_magic = [_]u8{ 'X', 'X', 'X', 'X' } ++ ([_]u8{0} ** 12);
    try testing.expectError(error.InvalidMagic, Reader.init(&bad_magic));
}

test "reader: UnsupportedVersion" {
    const bad_version = [_]u8{ 'P', 'N', 'G', 'B', 0xFF, 0xFF } ++ ([_]u8{0} ** 10);
    try testing.expectError(error.UnsupportedVersion, Reader.init(&bad_version));
}

// ... test for every error variant
```

#### Opcode Coverage Matrix

Every opcode must have dedicated tests:

| Opcode | Unit Test | Integration Test | Error Test |
|--------|-----------|------------------|------------|
| `create_buffer` (0x01) | ✓ | ✓ | Invalid size, usage |
| `create_texture` (0x02) | ✓ | ✓ | Invalid format, dimensions |
| `create_sampler` (0x03) | ✓ | ✓ | Invalid descriptor |
| `create_shader_module` (0x04) | ✓ | ✓ | Invalid data ID |
| `create_shader_concat` (0x05) | ✓ | ✓ | Zero fragments, invalid IDs |
| `create_bind_group` (0x0A) | ✓ | ✓ | Mismatched layout |
| `begin_render_pass` (0x10) | ✓ | ✓ | Nested pass |
| `set_pipeline` (0x12) | ✓ | ✓ | No active pass |
| `draw` (0x16) | ✓ | ✓ | No pipeline set |
| `dispatch` (0x18) | ✓ | ✓ | Invalid workgroup size |
| `write_buffer` (0x20) | ✓ | ✓ | Out of bounds |
| `fill_random` (0x52) | ✓ | ✓ | Invalid stride |
| `fill_expression` (0x55) | ✓ | ✓ | Stack overflow |
| `expr_div` (0x73) | ✓ | ✓ | Division by zero |
| ... | ... | ... | ... |

#### Expression VM Coverage

100% coverage of expression bytecode execution:

```zig
test "expr: every opcode" {
    // Arithmetic
    try testExpr(&[_]u8{ 0x60, f32Bytes(2.0), 0x60, f32Bytes(3.0), 0x70, 0x7F }, 5.0);  // add
    try testExpr(&[_]u8{ 0x60, f32Bytes(5.0), 0x60, f32Bytes(3.0), 0x71, 0x7F }, 2.0);  // sub
    try testExpr(&[_]u8{ 0x60, f32Bytes(4.0), 0x60, f32Bytes(3.0), 0x72, 0x7F }, 12.0); // mul
    try testExpr(&[_]u8{ 0x60, f32Bytes(6.0), 0x60, f32Bytes(2.0), 0x73, 0x7F }, 3.0);  // div

    // Math functions
    try testExpr(&[_]u8{ 0x60, f32Bytes(0.0), 0x78, 0x7F }, 0.0);    // sin(0)
    try testExpr(&[_]u8{ 0x60, f32Bytes(0.0), 0x79, 0x7F }, 1.0);    // cos(0)
    try testExpr(&[_]u8{ 0x60, f32Bytes(4.0), 0x7A, 0x7F }, 2.0);    // sqrt(4)
    try testExpr(&[_]u8{ 0x60, f32Bytes(-3.0), 0x7B, 0x7F }, 3.0);   // abs(-3)

    // Stack operations
    try testExpr(&[_]u8{ 0x60, f32Bytes(1.0), 0x64, 0x70, 0x7F }, 2.0);  // dup, add
    try testExpr(&[_]u8{ 0x60, f32Bytes(1.0), 0x60, f32Bytes(2.0), 0x65, 0x71, 0x7F }, 1.0);  // swap, sub

    // Special values
    try testExpr(&[_]u8{ 0x61, 0x7F }, 42.0);  // element_id (with id=42)
    try testExpr(&[_]u8{ 0x62, 0x7F }, 100.0); // element_count (with count=100)
}

test "expr: error conditions" {
    // Stack underflow
    try testing.expectError(error.StackUnderflow, execExpr(&[_]u8{ 0x70, 0x7F })); // add with empty stack

    // Stack overflow (push 17 values with max stack 16)
    var overflow_prog: [17 * 5 + 1]u8 = undefined;
    for (0..17) |i| {
        @memcpy(overflow_prog[i * 5 ..][0..5], &[_]u8{ 0x60 } ++ f32Bytes(1.0));
    }
    overflow_prog[85] = 0x7F;
    try testing.expectError(error.StackOverflow, execExpr(&overflow_prog));

    // Division by zero
    try testing.expectError(error.DivisionByZero, execExpr(&[_]u8{ 0x60, f32Bytes(1.0), 0x60, f32Bytes(0.0), 0x73, 0x7F }));
}
```

#### Fuzz Testing for Edge Cases

Use Zig's fuzz testing to find uncovered paths:

```zig
test "fuzz: tokenizer handles arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) !void {
            // Tokenizer must not crash on any input
            var tokenizer = Tokenizer.init(input);
            while (true) {
                const token = tokenizer.next();
                if (token.tag == .eof) break;
                // Verify token invariants
                assert(token.loc.end >= token.loc.start);
                assert(token.loc.end <= input.len);
            }
        }
    }.run, .{});
}

test "fuzz: varint handles arbitrary bytes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) !void {
            // Either succeeds or returns a defined error
            _ = readVarint(input) catch |err| switch (err) {
                error.UnexpectedEof => return,
            };
        }
    }.run, .{});
}
```

#### CI Coverage Gate

```yaml
# .github/workflows/test.yml
- name: Run tests with coverage
  run: |
    zig build test -ftest-coverage
    zig-cov report --fail-under=100 coverage.json

- name: Upload coverage report
  uses: codecov/codecov-action@v3
  with:
    files: coverage.json
    fail_ci_if_error: true
```

#### Coverage Exceptions (Must Be Justified)

Any line excluded from coverage must have a comment explaining why:

```zig
// COVERAGE: unreachable - this switch is exhaustive over all OpCode values
// The compiler guarantees this branch cannot be taken
else => unreachable,

// COVERAGE: platform-specific - only runs on WASM target
if (builtin.cpu_arch == .wasm32) {
    // WASM-specific initialization
}

// COVERAGE: defensive assertion - should never fail if code is correct
// Tested indirectly via integration tests that would fail if this triggers
assert(self.stack_depth <= MAX_STACK);
```

**Rule: No `unreachable` without justification. No uncovered error returns.**

---

## Stateless Viewer API

Matching viewer.ts interface:

```typescript
interface WorkerController {
    draw: (t: number, frameId?: string, inputs?: Record<string, any>) => void;
    ready: () => Promise<void>;
    read: (t: number, f?: string) => Promise<ImageData>;
    info: () => Promise<ShaderDiagnostics>;
    resumeVideos: () => Promise<void>;
    terminate: () => void;
}
```

**WASM exports must support:**
- `execute_frame(frame_id, time, inputs_ptr, inputs_len)`
- `get_shader_info() → ptr, len`
- `read_pixels(time, frame_id) → ptr, len`

---

## WASM Build Configuration

```zig
// build.zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // WASM target
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const exe = b.addExecutable(.{
        .name = "pngine",
        .root_source_file = b.path("src/main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    exe.rdynamic = true;
    exe.entry = .disabled;
    exe.root_module.link_libc = false;

    b.installArtifact(exe);

    // Native tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
```

---

## Size Reduction Analysis

From real demo analysis (inercia2025):

| Metric | Current JSON | Target Bytecode |
|--------|-------------|-----------------|
| File size | 1.7MB | ~50KB |
| Instruction count | 644 | ~200 opcodes |
| Avg per instruction | 2.6KB | ~50 bytes |
| Shader handling | Embedded JSON | Compressed data section |
| String paths | Repeated verbatim | String table + IDs |
| Interpreter size | 15KB JS | 25-35KB WASM |
| Parse overhead | JSON.parse | Zero (direct execution) |

**Shader deduplication (CreateShaderConcat):**
- Common preambles: 39% reduction
- Shared utility functions
- Per-shader unique code only

---

## Implementation Order

### Milestone 1: Core Infrastructure
- [ ] Varint encoding/decoding
- [ ] PNGB header parsing
- [ ] String table reader
- [ ] Data section reader
- [ ] Basic opcode dispatch

### Milestone 2: S-Expression Format
- [ ] PBSF tokenizer (labeled switch)
- [ ] PBSF parser (recursive descent)
- [ ] PBSF → PNGB assembler
- [ ] PNGB → PBSF disassembler

### Milestone 3: Executor Foundation
- [ ] Mock WebGPU infrastructure
- [ ] Resource table management
- [ ] Context (encoder/pass) handling
- [ ] All resource creation opcodes
- [ ] CreateShaderConcat (WGSL composition)

### Milestone 4: Runtime Features
- [ ] Pass/draw opcodes
- [ ] Queue operations
- [ ] Frame control
- [ ] Uniform system
- [ ] Pool/ping-pong

### Milestone 5: Data Generation
- [ ] Seeded PRNG (deterministic)
- [ ] TypedArray allocation (f32, u32, i32, f16)
- [ ] FillConstant, FillRandom (80% use cases)
- [ ] FillLinear, FillElementIndex (95% use cases)
- [ ] Expression VM (100% coverage)
- [ ] InitBufferFromArray, WriteArrayToBuffer

### Milestone 6: WASM Integration
- [ ] build.zig for WASM target
- [ ] Export functions (execute_frame, etc.)
- [ ] Import declarations (WebGPU calls)
- [ ] Memory management (malloc/free)

### Milestone 7: JS Runtime
- [ ] WASM loader
- [ ] WebGPU FFI bridge
- [ ] Handle management
- [ ] WebWorker integration
- [ ] Stateless viewer API

### Milestone 8: Compiler Pipeline
- [ ] DSL tokenizer
- [ ] DSL parser
- [ ] Macro → bytecode emission
- [ ] miniray integration for WGSL minification
- [ ] #data macro → runtime generation opcodes
- [ ] PNG bundler integration

### Milestone 9: Validation
- [ ] End-to-end tests
- [ ] Error handling (shader compilation, pipeline creation)
- [ ] Performance benchmarks
- [ ] Real demo conversion (inercia2025)

---

## Risk Mitigation

1. **WebGPU API coverage**: Start with minimal API surface, expand as needed
2. **WASM debugging**: Implement comprehensive logging via JS imports
3. **Memory management**: Use arena allocator, static allocation after init
4. **Browser compatibility**: Test across Chrome, Firefox, Safari WebGPU
5. **Shader composition edge cases**: Test with all existing demos

---

## Example-Driven Development Approach

### Philosophy

Build the system example-by-example, starting from the simplest case and adding features only when needed by the next example. Each example is a vertical slice that produces working software.

### Example Progression

| # | Example | New Features Required |
|---|---------|----------------------|
| 1 | `simpleTriangle` | Core: shader, render pipeline, render pass, frame, draw |
| 2 | `movingTriangle` | Uniforms (`time`), `#buffer`, bind groups, `#queue writeBuffer` |
| 3 | `rotatingCube` | Vertex buffers, depth texture, 3D transforms, `#data` literals |
| 4 | `rotatingTexturedCube` | `#texture`, `#sampler`, image loading, UV coordinates |
| 5 | `boids` | `#computePipeline`, `#computePass`, ping-pong pools, `#data` expressions |
| 6 | `rotatingCubeWASM` | WASM module loading, WASM data calls |

### Per-Example Process

```
1. Hand-write expected .pbsf for the example
2. Write tests: PBSF parsing → bytecode generation
3. Write tests: bytecode execution → Mock WebGPU calls verification
4. Implement executor opcodes to pass tests
5. Run with Mach (native WebGPU) → snapshot test
6. Run with WASM in browser → visual verification
7. Build DSL parser to generate the .pbsf automatically
```

---

## Native WebGPU Testing with Mach

Use [Mach](https://machengine.org/) (`sysgpu`) for native snapshot testing. This enables:
- Real WebGPU rendering without a browser
- Pixel-perfect snapshot comparisons
- CI testing with actual GPU output

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Test Runner (zig test)                   │
├─────────────────────────────────────────────────────────────┤
│  test "simpleTriangle renders correctly"                    │
│    1. Load .pngb bytecode                                   │
│    2. Create Mach headless device                           │
│    3. Execute bytecode (calls sysgpu API)                   │
│    4. Read pixels via copyTextureToBuffer + mapAsync        │
│    5. Compare with assets/simple-triangle-snapshot.png      │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     Mach sysgpu                             │
├─────────────────────────────────────────────────────────────┤
│  Native WebGPU implementation in Zig                        │
│  Backends: Metal (macOS), Vulkan (Linux), D3D12 (Windows)   │
└─────────────────────────────────────────────────────────────┘
```

### Mach Integration for Snapshot Testing

```zig
// test/snapshot.zig
const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;
const Executor = @import("../src/executor/core.zig").Executor;

pub const SnapshotTest = struct {
    device: gpu.Device,
    queue: gpu.Queue,
    render_texture: gpu.Texture,
    staging_buffer: gpu.Buffer,
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32) !SnapshotTest {
        // Create headless device (no window needed)
        const instance = gpu.createInstance(null);
        const adapter = instance.requestAdapter(&.{});
        const device = adapter.createDevice(null);
        const queue = device.getQueue();

        // Create render target texture
        const render_texture = device.createTexture(&gpu.Texture.Descriptor.init(.{
            .usage = .{ .render_attachment = true, .copy_src = true },
            .size = .{ .width = width, .height = height },
            .format = .rgba8_unorm,
        }));

        // Create staging buffer for pixel readback
        const bytes_per_row = ((width * 4 + 255) / 256) * 256; // Align to 256
        const staging_buffer = device.createBuffer(&gpu.Buffer.Descriptor{
            .usage = .{ .copy_dst = true, .map_read = true },
            .size = bytes_per_row * height,
        });

        return .{
            .device = device,
            .queue = queue,
            .render_texture = render_texture,
            .staging_buffer = staging_buffer,
            .width = width,
            .height = height,
        };
    }

    pub fn executeAndCapture(self: *SnapshotTest, executor: *Executor, frame_id: u32, time: f32) ![]u8 {
        // Execute bytecode frame (renders to self.render_texture)
        try executor.executeFrame(frame_id, time, self.render_texture.createView(null));

        // Copy texture to staging buffer
        const encoder = self.device.createCommandEncoder(null);
        encoder.copyTextureToBuffer(
            &.{ .texture = self.render_texture },
            &.{
                .buffer = self.staging_buffer,
                .layout = .{
                    .bytes_per_row = ((self.width * 4 + 255) / 256) * 256,
                    .rows_per_image = self.height,
                },
            },
            &.{ .width = self.width, .height = self.height },
        );
        self.queue.submit(&.{encoder.finish(null)});

        // Map and read pixels
        var result: ?[]u8 = null;
        self.staging_buffer.mapAsync(.{ .read = true }, 0, self.staging_buffer.size, &result, mapCallback);

        // Wait for mapping (device.tick() processes callbacks)
        while (result == null) {
            self.device.tick();
        }

        return result.?;
    }

    fn mapCallback(ctx: *?[]u8, status: gpu.Buffer.MapAsyncStatus) void {
        if (status == .success) {
            // Copy mapped data
            const data = self.staging_buffer.getConstMappedRange(u8, 0, self.staging_buffer.size).?;
            ctx.* = std.testing.allocator.dupe(u8, data) catch null;
        }
        self.staging_buffer.unmap();
    }
};

// Usage in tests
test "simpleTriangle snapshot" {
    var snapshot = try SnapshotTest.init(800, 600);
    defer snapshot.deinit();

    var executor = try Executor.init(&snapshot.device);
    defer executor.deinit();

    try executor.loadBytecode(@embedFile("fixtures/simple_triangle.pngb"));

    const pixels = try snapshot.executeAndCapture(&executor, 0, 0.0);
    defer std.testing.allocator.free(pixels);

    const expected = try loadPNG("assets/simple-triangle-snapshot.png");
    defer std.testing.allocator.free(expected);

    const diff = pixelDiff(pixels, expected);
    try std.testing.expect(diff < 0.01);
}
```

### Build Configuration for Mach

```zig
// build.zig
const std = @import("std");
const mach = @import("mach");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library (platform-agnostic executor)
    const lib = b.addStaticLibrary(.{
        .name = "pngine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Native tests with Mach (real WebGPU)
    const native_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link Mach for native WebGPU
    const mach_dep = b.dependency("mach", .{
        .target = target,
        .optimize = optimize,
    });
    native_tests.root_module.addImport("mach", mach_dep.module("mach"));

    const run_native_tests = b.addRunArtifact(native_tests);
    const test_step = b.step("test", "Run native tests with real WebGPU");
    test_step.dependOn(&run_native_tests.step);

    // WASM build (for browser)
    const wasm = b.addExecutable(.{
        .name = "pngine",
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSmall,
    });
    wasm.rdynamic = true;
    wasm.entry = .disabled;

    const wasm_step = b.step("wasm", "Build WASM for browser");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);
}
```

### Mach Dependency

```zig
// build.zig.zon
.{
    .name = "pngine",
    .version = "0.1.0",
    .dependencies = .{
        .mach = .{
            .url = "https://pkg.machengine.org/mach/...",
            .hash = "...",
        },
    },
}
```

---

## simpleTriangle: First Vertical Slice

### Target Output

Hand-written PBSF for simpleTriangle:

```lisp
(module "simpleTriangle"
  ;; Shader code in data section
  (data $d:0 "
    @vertex fn vertexMain(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
      var pos = array<vec2f, 3>(vec2(0.0, 0.5), vec2(-0.5, -0.5), vec2(0.5, -0.5));
      return vec4f(pos[i], 0.0, 1.0);
    }
    @fragment fn fragMain() -> @location(0) vec4f {
      return vec4f(1.0, 0.0, 0.0, 1.0);
    }
  ")

  ;; Create shader module from data section
  (shader $shd:0 (code $d:0))

  ;; Create render pipeline
  (render-pipeline $pipe:0
    (layout auto)
    (vertex $shd:0 (entry "vertexMain"))
    (fragment $shd:0 (entry "fragMain")
      (targets (target (format @preferredCanvasFormat))))
    (primitive (topology triangle-list)))

  ;; Define render pass
  (pass $pass:0 "renderPipeline"
    (render
      (color-attachments
        (attachment
          (view @swapchain)
          (clear-value 0 0 0 0)
          (load-op clear)
          (store-op store)))
      (commands
        (set-pipeline $pipe:0)
        (draw 3 1))))

  ;; Define frame
  (frame $frm:0 "simpleTriangle"
    (exec-pass $pass:0)
    (submit)))
```

### Implementation Checklist

**Phase 1: PBSF Parser (TDD)**
- [ ] Tokenizer: atoms, strings, numbers, parens, comments
- [ ] Parser: S-expression tree
- [ ] Test: parse simpleTriangle.pbsf → AST

**Phase 2: Bytecode Assembler (TDD)**
- [ ] String table builder
- [ ] Data section builder
- [ ] Opcode emitter for: `create_shader_module`, `create_render_pipeline`, `define_pass`, `begin_render_pass`, `set_pipeline`, `draw`, `end_pass`, `define_frame`, `exec_pass`, `submit`
- [ ] Test: AST → PNGB bytes

**Phase 3: Executor with Mock (TDD)**
- [ ] MockWebGPU: track createShaderModule, createRenderPipeline, draw calls
- [ ] Executor: dispatch opcodes, call mock
- [ ] Test: execute PNGB → verify mock received correct calls

**Phase 4: Executor with Mach (Integration)**
- [ ] Replace mock with real Mach sysgpu calls
- [ ] Render to texture
- [ ] Snapshot test: compare pixels to expected PNG

**Phase 5: WASM Build**
- [ ] build.zig WASM target
- [ ] Export functions: `init`, `loadBytecode`, `executeFrame`
- [ ] Import stubs for WebGPU (JS will provide)

**Phase 6: JS Integration**
- [ ] Minimal JS loader (reuse old_pngine viewer.ts pattern)
- [ ] WebGPU bridge: implement imported functions
- [ ] Visual test in browser

---

## Dual Executor Architecture

The executor has two modes sharing the same opcode dispatch:

```zig
// src/executor/core.zig
pub const Executor = struct {
    gpu: GPUBackend,  // Either MockGPU, MachGPU, or WasmGPU

    pub fn init(backend: GPUBackend) Executor {
        return .{ .gpu = backend };
    }

    pub fn executeOpcode(self: *Executor, opcode: OpCode, args: []const u8) !void {
        switch (opcode) {
            .create_shader_module => {
                const id = readVarint(args[0..]);
                const code_data_id = readVarint(args[id.len..]);
                const code = self.getDataSection(code_data_id);
                self.gpu.createShaderModule(id.value, code);
            },
            .draw => {
                const vertices = readVarint(args[0..]);
                const instances = readVarint(args[vertices.len..]);
                self.gpu.draw(vertices.value, instances.value);
            },
            // ... other opcodes
        }
    }
};

// Backend interface
pub const GPUBackend = union(enum) {
    mock: *MockGPU,
    mach: *MachGPU,
    wasm: *WasmGPU,

    pub fn createShaderModule(self: GPUBackend, id: u32, code: []const u8) void {
        switch (self) {
            .mock => |m| m.createShaderModule(id, code),
            .mach => |m| m.createShaderModule(id, code),
            .wasm => |w| w.createShaderModule(id, code),
        }
    }
};
```

This lets us:
1. **TDD with Mock**: Fast, no GPU needed, verify call sequences
2. **Integration with Mach**: Real rendering, snapshot tests
3. **Production with WASM**: Same executor, JS provides WebGPU
