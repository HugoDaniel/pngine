# Contributing to PNGine

This document captures practical knowledge for developers working on PNGine,
including architectural insights, debugging strategies, and common pitfalls
learned from real development experience.

## Architecture Overview

### Data Flow

```
DSL Source (.pngine)
    │
    ▼
Compiler (Zig)
    ├── Parser → AST
    ├── Analyzer → Semantic validation
    └── Emitter → Bytecode (PNGB)
           │
           ▼
    ┌──────────────────────────────────────┐
    │ PNGB Bytecode (embedded in PNG)      │
    │ - Header (16 bytes)                  │
    │ - Opcodes (resource creation, draws) │
    │ - String Table (entry points)        │
    │ - Data Section (WGSL code, buffers)  │
    └──────────────────────────────────────┘
           │
           ▼
WASM Executor (wasm_entry.zig)
    ├── Parses bytecode opcodes
    ├── Reads data from Data Section
    └── Emits Command Buffer
           │
           ▼
JS Host (gpu.js)
    ├── Executes Command Buffer
    └── Calls WebGPU APIs
           │
           ▼
GPU (renders to canvas)
```

### Key Insight: Two Opcode Sets

PNGine has **two separate opcode enumerations** that can be confusing:

| Opcode Set | File | Purpose | Example Range |
|------------|------|---------|---------------|
| PNGB Bytecode | `src/types/opcodes.zig` | Stored in compiled `.pngb` files | Data-gen: `0x50-0x55` |
| Command Buffer | `src/executor/command_buffer.zig` | Runtime JS communication | Data-gen: `0x40-0x44` |

**How they relate**:
1. Compiler emits **PNGB opcodes** into the `.pngb` bytecode file
2. WASM executor reads PNGB opcodes and translates them to **Command Buffer** format
3. JS `gpu.js` processes **Command Buffer opcodes** (NOT PNGB opcodes)

**Why this matters**: When adding data-generation features or debugging opcode issues,
you must identify which opcode set is relevant. The JS runtime (`gpu.js`) will never
see PNGB opcodes directly—it only sees Command Buffer opcodes.

**Common confusion**: Documentation may reference "opcode 0x50" (PNGB) but the JS
sees "opcode 0x40" (Command Buffer) for the same logical operation.

### Key Insight: Multiple ID Systems

PNGine uses several distinct ID systems that can be confusing:

| ID Type | Defined In | Purpose | Used By |
|---------|------------|---------|---------|
| `wgsl_id` | `wgsl_table.zig` | Index in WGSL module table | Compiler internal |
| `data_id` | `data_section.zig` | Index in bytecode data section | Bytecode/Executor |
| `shader_id` | Emitter | Logical shader resource ID | Pipelines |
| `buffer_id` | Emitter | Logical buffer resource ID | Bind groups |

**Critical**: The WASM executor (`wasm_entry.zig`) uses `data_id` to look up data
via `getDataSlice()`. When emitting bytecode, always pass `data_id`, not `wgsl_id`.

### Data Section Contents

The data section stores raw bytes referenced by `data_id`. Contents include:

1. **Expression strings** from `#data` blocks with `initEachElementWith`
2. **WGSL shader code** from `#wgsl` and `#shaderModule`
3. **Static float arrays** from `#data` blocks
4. **Descriptor data** for pipelines and bind groups

The order data is added determines the `data_id` assigned. Expression strings
from `#data` blocks are typically added first, pushing WGSL code to higher IDs.

## Common Pitfalls

### 1. Shader Gets Wrong Data

**Symptom**: `createShader(id=0, len=42, first50chars="cos((ELEMENT_ID...")` -
shader receives expression string instead of WGSL code.

**Cause**: Bytecode emitter passed `wgsl_id` but executor expected `data_id`.

**Fix Location**: `src/dsl/emitter/shaders.zig` - use `data_id.toInt()` in
`createShaderModule` calls.

**Test Case**: Any `.pngine` file with both `#data` blocks containing expressions
AND a `#shaderModule` with inline code.

### 2. Resource ID Mismatch

**Symptom**: Pipeline creation fails, "shader not found" errors.

**Cause**: Shader IDs weren't assigned when code was empty/invalid.

**Prevention**: The emitter skips empty shaders but must ensure IDs remain
consecutive. Test with empty `#wgsl` blocks mixed with valid ones.

### 3. Pool Buffer Confusion

**Symptom**: Ping-pong buffers use wrong buffer on alternating frames.

**Key Formula**: `actual_id = base_id + (frame_counter + offset) % pool_size`

**Testing**: Use `#buffer { pool=2 }` and verify alternation with debug logging.

### 4. pngineInputs Buffer Size Mismatch (Silent Failure)

**Symptom**: Animation doesn't animate, shader receives stale/zero time values,
or cube renders but doesn't rotate.

**Cause**: `pngineInputs` is always 16 bytes (4 x f32), but uniform buffer was
sized smaller. Writing 16 bytes to a 12-byte buffer causes WebGPU to silently
fail or produce undefined behavior.

**pngineInputs layout (16 bytes total)**:
| Field | Type | Offset | Description |
|-------|------|--------|-------------|
| `time` | f32 | 0 | Elapsed seconds since start |
| `canvasW` | f32 | 4 | Canvas width in pixels |
| `canvasH` | f32 | 8 | Canvas height in pixels |
| `aspect` | f32 | 12 | width / height |

**Wrong** (causes silent buffer overflow):
```
#buffer uniformInputsBuffer {
  size="4+4+4"              // 12 bytes - TOO SMALL!
  usage=[UNIFORM COPY_DST]
}
```

**Correct**:
```
#buffer uniformInputsBuffer {
  size="4+4+4+4"            // 16 bytes - matches pngineInputs
  usage=[UNIFORM COPY_DST]
}
```

**Also check**: The WGSL shader struct must match exactly:
```wgsl
struct PngineInputs {
  time: f32,
  canvasW: f32,    // NOT u32!
  canvasH: f32,    // NOT u32!
  aspect: f32,     // Must include this field
};
```

### 5. Wrong Data Source for Time Uniform

**Symptom**: `writeBuffer` creates buffer but shader gets wrong/zero values.

**Cause**: Using `data=code.inputs` or similar instead of the built-in
`pngineInputs` identifier.

**Wrong**:
```
#queue writeInputUniforms {
  writeBuffer={
    buffer=uniformInputsBuffer
    data=code.inputs          // WRONG - doesn't exist
  }
}
```

**Correct**:
```
#queue writeInputUniforms {
  writeBuffer={
    buffer=uniformInputsBuffer
    data=pngineInputs         // Built-in: runtime provides time/canvas data
  }
}
```

### 6. Missing COPY_DST for writeBuffer (Silent Failure)

**Symptom**: Render pass executes but screen is BLACK. No WebGPU errors shown.
Console logs show `writeBuffer` call appears successful, but buffer data is empty.

**Cause**: Buffer was created with `usage=[VERTEX]` but `writeBuffer` requires
`COPY_DST` flag. WebGPU silently fails to write data - the buffer remains empty.

**Wrong**:
```
#buffer boidBuffer {
  size=320
  usage=[VERTEX]           // Missing COPY_DST!
}

#queue initBuffer {
  writeBuffer={ buffer=boidBuffer data=boidData }  // Silently fails!
}
```

**Correct**:
```
#buffer boidBuffer {
  size=320
  usage=[VERTEX COPY_DST]  // Required for writeBuffer
}
```

**Debug hint**: Check console for `createBuffer(id, size, 0x20)` - if you see
`0x20` (VERTEX only) but later see `writeBuffer(id=...)`, that's the bug.
Correct usage shows `0x28` (VERTEX | COPY_DST).

### 7. Unused Shader Binding with layout=auto (Silent Failure)

**Symptom**: Render/compute pass executes but screen is BLACK. No WebGPU errors.
Bind groups appear to be created correctly in logs.

**Cause**: When using `layout=auto`, WebGPU generates bind group layouts that
only include **actually used** bindings. If a shader declares a binding but
never reads from it, that binding is optimized out. The bind group you create
(with all declared bindings) then doesn't match the auto-generated layout.

**Example scenario** (from 21_flocking_variations.pngine):
```wgsl
// Step shader declares uniforms but NEVER USES them
@group(0) @binding(0) var<uniform> u: Uniforms;  // DECLARED
@group(0) @binding(1) var<storage, read> boidsIn: Boids;
@group(0) @binding(2) var<storage, read_write> boidsOut: Boids;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  boidsOut.data[id.x] = boidsIn.data[id.x];  // Never reads u!
}
```

**What happens**:
1. Auto-layout sees uniforms is unused → generates layout with bindings [1, 2]
2. DSL creates bind group with entries for bindings [0, 1, 2]
3. Layout mismatch → bind group silently fails → BLACK screen

**Fix options**:
1. **Remove unused binding** from shader AND bind group (recommended):
```wgsl
@group(0) @binding(0) var<storage, read> boidsIn: Boids;
@group(0) @binding(1) var<storage, read_write> boidsOut: Boids;
```

2. **Actually use the binding** (if you need it):
```wgsl
@group(0) @binding(0) var<uniform> u: Uniforms;
// ... in main():
let t = u.time;  // Force the binding to be "used"
```

**Debug hints**:
- Compare working vs broken: If same shader works without a binding, that binding was unused
- Check if a passthrough version (just copying data) works but full logic fails
- Look for bind groups with 3 entries where layout expects 2

**Key lesson**: With `layout=auto`, every declared `@binding` MUST be read in
the shader code. Unused declarations cause silent bind group layout mismatches.

### 8. WASM Module Import Missing (env.abort)

**Symptom**: `Failed to load WASM module: {}` when using `#wasmCall`.

**Cause**: AssemblyScript-compiled WASM modules require `env.abort` import.
The error object is empty because the import validation fails silently.

**Fix**: Ensure gpu.js `_initWasmModule` provides the abort function:
```javascript
const imports = {
  env: {
    abort: (msg, file, line, col) => {
      console.error(`WASM abort at ${file}:${line}:${col}: ${msg}`);
    },
  }
};
```

### 9. Deprecated `numberOfElements + initEachElementWith` Syntax (Size=0 Buffer)

**Symptom**: Buffers created with `size=0` in `pngine check` output. The buffer
intended to hold compute-generated data is empty.

**Cause**: The old `#data` syntax with `numberOfElements` and `initEachElementWith`
is no longer supported:

```
// DEPRECATED - No longer works!
#data particleData {
  float32Array={
    numberOfElements=1024
    initEachElementWith=[
      "(random() * 2) - 1"
      "(random() * 2) - 1"
      "0.0"
      "1.0"
    ]
  }
}

#buffer particles {
  size=particleData                    // Results in size=0!
  usage=[VERTEX STORAGE]
  mappedAtCreation=particleData        // Data never written!
}
```

**Fix**: Use `#init` with a compute shader for initialization:

```
#define NUM_PARTICLES="1024"

#buffer particles {
  size="NUM_PARTICLES * 4 * 4"         // Explicit size calculation
  usage=[VERTEX STORAGE]
  pool=2
}

#shaderModule initParticlesShader {
  code="
    struct Particle { pos: vec4f }
    struct Particles { data: array<Particle> }
    @binding(0) @group(0) var<storage, read_write> p: Particles;

    fn hash(n: u32) -> f32 { /* deterministic hash */ }

    @compute @workgroup_size(64)
    fn main(@builtin(global_invocation_id) id: vec3u) {
      let i = id.x;
      if (i >= 1024u) { return; }
      p.data[i].pos = vec4f(
        hash(i * 7u) * 2.0 - 1.0,
        hash(i * 11u) * 2.0 - 1.0,
        0.0, 1.0
      );
    }
  "
}

#init initParticles {
  buffer=particles
  shader=initParticlesShader
  workgroups="ceil(NUM_PARTICLES / 64)"
}
```

**Key lesson**: For procedural buffer initialization, always use `#init` with a
compute shader. The `numberOfElements + initEachElementWith` syntax was removed
because compute shaders are more flexible and the expressions ran at compile-time
which limited functionality.

### 10. WASM Call Args Receive Zeros (Stack Pointer Bug)

**Symptom**: `#wasmCall` function receives zeros instead of canvas.width/height/time.
Console shows `raw args bytes: [0, 0, 0, 0]` but should be `[3, 1, 2, 3]`.

**Cause**: The WASM executor was passing a pointer to a stack-allocated buffer
(`args_buf`) to the command buffer. When the command buffer was later executed
by JavaScript, the stack memory was stale/overwritten.

**Root Cause Chain**:
1. Dispatcher reads args from bytecode into stack buffer `args_buf[256]`
2. `callWasmFunc()` was called with `@intFromPtr(&args_buf)` + `args.len`
3. Command buffer stored just the pointer and length (8 bytes)
4. JS later reads from that pointer, but stack is long gone → zeros

**Fix**: Args are now copied **inline** into the command buffer:
- `command_buffer.zig`: Changed `callWasmFunc` to take `args: []const u8` and
  write bytes inline using `writeSlice(args)`
- `gpu.js`: Changed decoder to read `argsLen: u8` at pos+12, then read that many
  bytes directly from command buffer (not from a memory pointer)

**Command buffer format changed from**:
```
[call_id:u16][module_id:u16][name_ptr:u32][name_len:u32][args_ptr:u32][args_len:u32]
```
**To**:
```
[call_id:u16][module_id:u16][name_ptr:u32][name_len:u32][args_len:u8][args bytes...]
```

**Files Modified**:
- `src/executor/command_buffer.zig` - Added `writeSlice`, changed `callWasmFunc`
- `src/wasm_entry.zig` - Updated call to pass slice directly
- `npm/pngine/src/gpu.js` - Updated decoder and `_callWasmFunc`, `_decodeWasmArgs`

### 11. Animation Scene Selection Not Implemented (Black Screen for Multi-Scene Demos)

**Symptom**: Demo with `#animation` timeline shows black screen even though
`pngine check` validates successfully and shows multiple draw calls.

**Cause**: The WASM executor's `executeFrame()` function in `wasm_entry.zig`
does not implement animation scene selection. It always executes the **first**
`define_frame` opcode found, regardless of the current time or animation table.

**Technical Details**:
```zig
// Current behavior (wasm_entry.zig executeFrame):
// 1. Scans bytecode for first define_frame
// 2. Executes that frame's body
// 3. Ignores animation_table and time parameter
```

**Example**: demo2025 defines:
```
#animation inercia2025 {
  scenes=[
    { id="intro" frame=sceneU start=0 end=2 }
    { id="boxes" frame=sceneE start=2 end=14 }
    ...
  ]
}
```

At time t=10s, it should show sceneE (boxes), but it always shows sceneU (intro)
because that's the first frame in bytecode order.

**Workaround**: For now, demos with `#animation` will only show the first scene.
Single-frame demos work correctly.

**Proper Fix Required**: Implement animation scene selection in `wasm_entry.zig`:
1. Load animation table during `init()`
2. In `executeFrame(time, ...)`, look up active scene from animation table
3. Find that scene's frame by name/ID
4. Execute that specific frame instead of first one

**Files Affected**:
- `src/wasm_entry.zig` - Add animation table parsing and scene lookup
- `src/bytecode/animation_table.zig` - May need WASM-friendly deserialization

**Key lesson**: The PNGB format supports multi-scene animations, but the WASM
runtime doesn't yet implement scene selection. This is tracked as a future
enhancement.

### 12. wgpu-native C Struct Initialization (iOS/Native - "invalid store op" panic)

**Symptom**: iOS app crashes with Rust panic: `invalid store op for render pass color attachment`
or similar "invalid X for Y" messages from wgpu-native.

**Cause**: Zig's @cImport creates struct types where uninitialized fields are `undefined`
(garbage memory), not zeroed. wgpu-native's validation rejects these garbage values.

**Wrong** (garbage in unset fields):
```zig
// Fields not explicitly set remain 'undefined' (garbage)
const color_attachment = c.WGPURenderPassColorAttachment{
    .view = view,
    .loadOp = c.WGPULoadOp_Clear,
    .storeOp = c.WGPUStoreOp_Store,
    // .nextInChain = undefined  ← GARBAGE!
    // .depthSlice = undefined   ← GARBAGE!
    // etc.
};
```

**Correct** (zero-initialize first):
```zig
// Zero-initialize struct to avoid undefined memory issues
var color_attachment = std.mem.zeroes(c.WGPURenderPassColorAttachment);
color_attachment.view = view;
color_attachment.loadOp = c.WGPULoadOp_Clear;
color_attachment.storeOp = c.WGPUStoreOp_Store;
color_attachment.clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
// All other fields are now safely zero/null
```

**Also note**: wgpu-native enum values differ from bytecode encoding:

| Operation | Bytecode Value | wgpu-native Value |
|-----------|---------------|-------------------|
| Load | 0 | `WGPULoadOp_Load = 2` |
| Clear | 1 | `WGPULoadOp_Clear = 2` |
| Store | 0 | `WGPUStoreOp_Store = 1` |
| Discard | 1 | `WGPUStoreOp_Discard = 2` |

**Mapping in code**:
```zig
const wgpu_load_op: c_uint = if (load_op == 0) c.WGPULoadOp_Load else c.WGPULoadOp_Clear;
const wgpu_store_op: c_uint = if (store_op == 0) c.WGPUStoreOp_Store else c.WGPUStoreOp_Discard;
```

**Files affected**: `src/executor/wgpu_native_gpu.zig` - all functions creating C structs

**Key lesson**: When working with wgpu-native (or any C library) through @cImport,
always use `std.mem.zeroes(T)` for struct initialization, then set only the fields you need.

## Debugging Strategies

### 1. Browser Console Logging

Enable debug mode to see GPU commands:

```javascript
// In browser console or URL parameter
localStorage.setItem('pngine_debug', 'true');
// or: http://localhost:5173/?debug=true
```

Look for prefixes:
- `[GPU]` - Command execution in gpu.js
- `[Worker]` - Worker thread events
- `[Executor]` - WASM executor logs

### 2. Chrome DevTools MCP (Recommended for WebGPU)

Headless browsers often fail to get WebGPU adapters. Use real Chrome:

```bash
# Launch Chrome with debugging
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chrome-debug-profile &

# Start dev server
npm run dev

# Use MCP tools to navigate and inspect
```

### 3. Bytecode Validation

```bash
# Check compiled bytecode
./zig-out/bin/pngine check output.png

# Output shows:
# - Resource counts (shaders, buffers, pipelines)
# - Entry point names
# - Buffer usage flags
# - Warnings about missing bind groups
```

### 4. Minimal Test Cases

Create minimal `.pngine` files to isolate issues:

```
# Minimal shader test (no #data)
#shaderModule code { code="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
#renderPipeline pipe { vertex={ module=code } }
#frame main { perform=[] }
```

```
# Test with #data before shader
#data testData { float32Array=["1.0" "2.0"] }
#shaderModule code { code="@fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
#frame main { perform=[] }
```

### 5. Adding Debug Output (Temporary)

For deep debugging, add prints in Zig:

```zig
std.debug.print("[DEBUG] shader_id={d}, data_id={d}, code_len={d}\n", .{
    shader_id,
    data_id.toInt(),
    code.len,
});
```

**Remember**: Remove debug prints before committing!

## Testing

### Test Hierarchy

```bash
# Fast: Individual module tests (~3s compile)
zig build test-types        # Core types
zig build test-bytecode     # Bytecode format
zig build test-executor     # Dispatcher + mock GPU

# Medium: DSL chain (~1min)
zig build test-dsl-complete # Full compilation tests

# Full: Everything including CLI (~5min)
zig build test
```

### Writing Regression Tests

For bugs involving bytecode generation, add tests to
`src/dsl/emitter/shader_id_test.zig` or similar:

```zig
test "ShaderID: shader with data blocks gets correct WGSL code" {
    const source: [:0]const u8 =
        \\#data testData { float32Array=["1.0"] }
        \\#shaderModule code { code="@vertex fn vs() ..." }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Execute and verify shader gets WGSL, not expression
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // ... verify shader code via mock GPU calls
}
```

### Browser Test Files

Create test HTML files in `demo/` directory:

```html
<!DOCTYPE html>
<html>
<head><title>Test Case Name</title></head>
<body>
  <canvas id="canvas" width="512" height="512"></canvas>
  <script type="module">
    import { pngine, play } from './pngine.js';
    const engine = await pngine('test_case.png', {
      canvas: document.getElementById('canvas'),
      debug: true
    });
    play(engine);
  </script>
</body>
</html>
```

## Built-in Shape Generators

### Overview

The DSL supports built-in shape generators that create vertex data at compile time.
This replaces manual vertex data entry for common shapes like cubes and planes.

### Usage

```
#data cubeVertices {
  cube={ format=[position4 color4 uv2] }
}

#buffer vb {
  size=cubeVertices
  usage=[VERTEX]
  mappedAtCreation=cubeVertices
}
```

### Supported Shapes

| Shape | Vertices | Description |
|-------|----------|-------------|
| `cube` | 36 | Unit cube (-1 to 1), per-face colors |
| `plane` | 6 | XY plane quad (-1 to 1) |

### Format Specifiers

| Format | Size | Description |
|--------|------|-------------|
| `position3` | 12B | vec3f position (x, y, z) |
| `position4` | 16B | vec4f position (x, y, z, 1) |
| `normal3` | 12B | vec3f face normal |
| `color3` | 12B | vec3f RGB color |
| `color4` | 16B | vec4f RGBA color |
| `uv2` | 8B | vec2f texture coordinates |

### Key Implementation Details

1. **Shape generators run at compile time** - No runtime CPU cost
2. **Format order matters** - Stride = sum of format sizes in order
3. **Use `findPropertyValueInObject`** - Shape config is an object node, not macro node
4. **Data stored in data_ids** - Size lookup via `e.builder.getDataSize(data_id)`

### Example: Cube Vertex Count Calculation

```
format=[position4 color4 uv2]
stride = 16 + 16 + 8 = 40 bytes
cube_vertices = 36 (6 faces × 2 triangles × 3 vertices)
total_size = 36 × 40 = 1440 bytes
```

### Adding New Shapes

1. Add generator function in `src/dsl/emitter/shapes.zig`
2. Add shape type to `ShapeType` enum in `resources.zig`
3. Add property check in `emitData()` function
4. Add tests in `src/dsl/emitter/test.zig`

## Code Organization

### Where to Add Features

| Feature Type | Location |
|--------------|----------|
| New DSL macro | `Token.zig` → `Parser.zig` → `Analyzer.zig` → `Emitter.zig` |
| New opcode | `opcodes.zig` → `emitter.zig` → `dispatcher.zig` → `mock_gpu.zig` |
| New GPU command | `command_buffer.zig` → `gpu.js` |
| New shape generator | `shapes.zig` → `resources.zig` (emitData) |
| New test | Appropriate `*_test.zig` file |

### File Size Guidelines

- Keep files under ~500 lines for LLM-friendliness
- Extract tests to `*/test.zig` subdirectories
- Split large emitters by resource type (shaders.zig, resources.zig, etc.)

## Zig Conventions

Follow the Zig mastery guidelines in CLAUDE.md:

1. **No recursion** - Use explicit stacks
2. **Bounded loops** - `for (0..MAX) |_| { } else unreachable`
3. **2+ assertions per function** - Pre/post conditions
4. **Explicit types** - `u32`, `i64`, not `usize` (except slice indexing)
5. **Functions <= 70 lines** - Exception: state machines

### Example Pattern

```zig
pub fn processShaders(e: *Emitter) Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const max_shaders = 256;
    for (0..max_shaders) |_| {
        const shader = e.getNextShader() orelse break;
        try e.emitShader(shader);
    } else unreachable; // Hit max without finishing

    // Post-condition
    std.debug.assert(e.shader_count <= max_shaders);
}
```

## Pull Request Checklist

- [ ] Tests pass: `zig build test-dsl-complete --summary all`
- [ ] No debug prints left in code
- [ ] Browser test verified (if UI-related)
- [ ] Commit message follows convention: `type(scope): description`
- [ ] New features have corresponding tests

## Common Commands

```bash
# Build
zig build                    # CLI binary
zig build web               # WASM + JS for browser

# Test
zig build test-standalone --summary all  # All standalone (parallel)
zig build test-dsl-complete             # DSL chain only

# Run
./zig-out/bin/pngine check output.png   # Validate bytecode
./zig-out/bin/pngine input.pngine -o output.png  # Compile

# Browser
npm run dev                 # Start Vite dev server
# Navigate to http://localhost:5173/

# iOS Testing (Swift Package Manager doesn't support iOS targets directly)
xcodebuild test -scheme PngineKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:PngineKitTests
```

### 13. Resource Recreation Bug - Buffers Cleared on Frame 2+ (Native Only)

**Symptom**: Particles or other compute-initialized data renders correctly on frame 1,
but shows all particles at origin (0,0) or empty buffers starting from frame 2+.

**Cause**: The native executor (`pngine_render`) resets PC to 0 and re-executes ALL
bytecode every frame. This caused resource creation opcodes (create_buffer, create_pipeline,
etc.) to overwrite existing resources with empty ones. Combined with `exec_pass_once`
only running init compute passes once, this meant:

1. Frame 1: Create buffer → Run compute → Buffer filled with data → Render works!
2. Frame 2+: Recreate buffer (EMPTY!) → Skip compute (exec_pass_once) → Render fails!

**Fix Applied** (in `wgpu_native_gpu.zig`): Added skip checks to all resource creation functions:

```zig
pub fn createBuffer(self: *Self, ..., buffer_id: u16, ...) !void {
    // Skip if buffer already exists (resources are created once, not per-frame)
    if (self.buffers[buffer_id] != null) {
        return;
    }
    // ... actual creation code
}
```

Functions with skip logic:
- `createBuffer`
- `createTexture`
- `createSampler`
- `createShaderModule`
- `createRenderPipeline`
- `createComputePipeline`
- `createBindGroup`

**Known Limitation - Resize**: If you call `pngine_resize()` to change canvas dimensions,
textures that use canvas-size defaults will NOT be recreated with new dimensions.
The skip logic prevents recreation. For now, destroy and recreate the animation
if you need to resize. This primarily affects depth textures.

**Why this doesn't affect web**: The JS runtime (`gpu.js`) tracks resources and
skips recreation at the JS level. The native backend needed the same protection.

**Debug verification**: Use `pngine_debug_compute_counters()` to verify bind group count.
Before fix: `bg=31` (growing each frame). After fix: `bg=1` (created once).

**Pool buffers work correctly**: Pool buffers (e.g., `pool=2` for ping-pong) have
different IDs (buffer_0, buffer_1), so skip logic doesn't interfere. The selection
happens at runtime via `set_vertex_buffer_pool` which calculates:
```
actual_id = base_id + (frame_counter + offset) % pool_size
```

**Files affected**: `src/executor/wgpu_native_gpu.zig`

**Key lesson**: Native backends need explicit resource deduplication since bytecode
execution is stateless (PC resets each frame). The JS backend gets this implicitly
through object identity.

## Getting Help

- Check `CLAUDE.md` for detailed architecture docs
- Look at `docs/*.md` for implementation plans
- Run `pngine check` on bytecode to validate structure
- Enable debug mode in browser for detailed logging
