# Data Initialization Plan

> **Context References**:
> - Main project guide: `CLAUDE.md`
> - Embedded executor plan: `docs/embedded-executor-plan.md`
> - Data generation plan: `docs/data-generation-plan.md` (superseded)
>
> **Dependencies**:
> - **miniray 0.3.0+** - Required for WGSL reflection with memory layout computation
>   - Rebuild: `cd ../../miniray && make lib`
>   - Features used: `miniray_reflect()` for struct sizes, array strides, field offsets
>   - See: `/Users/hugo/Development/miniray/BUILDING_WITH_MINIRAY.md`

---

## Executive Summary

This plan simplifies data initialization by:

1. **Adding `#init` macro** for declarative GPU buffer initialization
2. **Adding auto-sizing via shader reflection** (`size=shaderName.varName`)
3. **Supporting dynamic params** for per-frame re-initialization
4. **Removing data-gen opcodes** (0x40-0x44 from command buffer, 0x50-0x55 from PNGB)
5. **Keeping WASM-in-WASM** for edge cases (determinism, external libs)

**Result**: Single source of truth in shaders, compile-time validation, ergonomic syntax.

---

## Current State: Too Much Boilerplate

To initialize a buffer with computed data today, you need 6+ declarations:

```
#wgsl initShader { value="..." }
#buffer params { size=16 usage=[UNIFORM] data=[...] }
#computePipeline initPipeline { compute={ module=initShader entryPoint="main" } }
#bindGroup initBindGroup { layout={ pipeline=initPipeline index=0 } entries=[...] }
#computePass initPass { pipeline=initPipeline bindGroups=[initBindGroup] dispatch=[...] }
#frame init { perform=[initPass] runOnce=true }
```

This is tedious for a conceptually simple operation.

---

## Proposed Solution: `#init` Macro + Auto-Sizing

### Core Idea: Shader as Source of Truth

The particle count is defined ONCE in the shader's array type:

```wgsl
struct Particle { pos: vec3f, vel: vec3f }

// Array size (10000) is the single source of truth
@group(0) @binding(0) var<storage, read_write> data: array<Particle, 10000>;
@group(0) @binding(1) var<uniform> params: vec4u;  // seed, _, _, _

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  if (id.x >= arrayLength(&data)) { return; }
  // ... initialization logic
}
```

### DSL Syntax

```
#wgsl initParticles {
  value="
    struct Particle { pos: vec3f, vel: vec3f }
    @group(0) @binding(0) var<storage, read_write> data: array<Particle, 10000>;
    @group(0) @binding(1) var<uniform> params: vec4u;

    @compute @workgroup_size(64)
    fn main(@builtin(global_invocation_id) id: vec3u) {
      if (id.x >= arrayLength(&data)) { return; }
      var seed = params.x + id.x;
      // ... pcg, spherePoint, etc.
      data[id.x] = Particle(pos, vel);
    }
  "
}

#buffer particles {
  size=initParticles.data       // Auto-size from shader reflection!
  usage=[VERTEX STORAGE]
}

#init resetParticles {
  buffer=particles
  shader=initParticles
  params=[12345 0 0 0]          // seed=12345
}

#frame main {
  init=[resetParticles]         // Runs once before first frame
  perform=[updatePass renderPass]
}
```

### What the Compiler Does

1. **Parses WGSL** to reflect `initParticles.data` → `array<Particle, 10000>`
2. **Calculates size**: `10000 * sizeof(Particle)` = `10000 * 24` = `240000` bytes
3. **Validates** buffer size matches shader expectation
4. **Auto-calculates dispatch**: `ceil(10000 / 64)` = `157` workgroups
5. **Generates**: compute pipeline, params buffer, bind group, dispatch commands

---

## Auto-Sizing via Shader Reflection

### Syntax

```
size=<shader_id>.<var_name>
```

### How It Works

The compiler:

1. Parses the referenced WGSL shader
2. Finds the variable by name
3. Determines its type and calculates byte size
4. Uses that size for the buffer

### Examples

```
// From fixed-size array
#buffer particles {
  size=initParticles.data    // array<Particle, 10000> → 240000 bytes
  usage=[VERTEX STORAGE]
}

// From struct
#buffer uniforms {
  size=mainShader.camera     // struct Camera { ... } → sizeof(Camera)
  usage=[UNIFORM COPY_DST]
}

// From another buffer (reference)
#buffer particlesCopy {
  size=particles             // Same size as particles buffer
  usage=[STORAGE COPY_DST]
}
```

### Supported Types for Reflection

| WGSL Type | Size Calculation |
|-----------|------------------|
| `array<T, N>` | `N * sizeof(T)` |
| `array<T>` | Error: runtime-sized arrays need explicit size |
| `struct { ... }` | Sum of field sizes (with padding) |
| `vec2<f32>` | 8 bytes |
| `vec3<f32>` | 12 bytes |
| `vec4<f32>` | 16 bytes |
| `mat4x4<f32>` | 64 bytes |
| `f32`, `i32`, `u32` | 4 bytes |

### Error Cases

```
// Error: Variable not found
size=initParticles.nonexistent
// → Compiler error: "Variable 'nonexistent' not found in shader 'initParticles'"

// Error: Runtime-sized array
size=initParticles.dynamicData  // var<storage> dynamicData: array<f32>;
// → Compiler error: "Cannot auto-size from runtime-sized array 'dynamicData'"

// Error: Shader not found
size=unknownShader.data
// → Compiler error: "Shader 'unknownShader' not found"
```

---

## Dynamic Params for Per-Frame Init

### Static Params (Run Once)

```
#init resetParticles {
  buffer=particles
  shader=initParticles
  params=[12345 0 0 0]         // Static: seed=12345
}

#frame main {
  init=[resetParticles]        // Runs ONCE before first frame
  perform=[renderPass]
}
```

### Dynamic Params (Run Every Frame)

Use runtime values like `time.total`, `canvas.width`:

```
#init resetParticles {
  buffer=particles
  shader=initParticles
  params=[time.total 0 0 0]    // Dynamic: seed changes each frame
}

#frame main {
  perform=[resetParticles renderPass]  // Runs EVERY frame
}
```

### Supported Runtime Values

| Value | Type | Description |
|-------|------|-------------|
| `time.total` | f32 | Elapsed seconds since start |
| `time.delta` | f32 | Delta since last frame |
| `canvas.width` | u32 | Canvas width in pixels |
| `canvas.height` | u32 | Canvas height in pixels |

These use the same encoding as `#wasmCall` args (WasmArgType in opcodes.zig).

---

## `#init` Macro Specification

### Syntax

```
#init <name> {
  shader=<wgsl_ref>             // Required: compute shader
  bindings={                    // Optional: explicit buffer-to-variable mapping
    <var_name>=<buffer_ref>
    ...
  }
  params=[...]                  // Optional: param values (static or dynamic)
  entryPoint="main"             // Optional: defaults to "main"
  dispatch=[x y z]              // Optional: override auto-calculated dispatch
}
```

### Properties

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `shader` | identifier | Yes | - | WGSL compute shader |
| `bindings` | object | No | auto | Maps shader variables to buffers |
| `params` | array | No | `[0 0 0 0]` | 4 x u32 params (static or dynamic) |
| `entryPoint` | string | No | `"main"` | Shader entry point |
| `dispatch` | array | No | auto | Override workgroup dispatch count |

### Auto-Binding via Reflection (Shader as Source of Truth)

The compiler uses miniray reflection to extract `@group/@binding` declarations from
the shader, then automatically binds buffers. **No fixed binding convention required.**

#### Binding Resolution Order

1. **Explicit bindings**: If `bindings={ varName=bufferRefId }` is specified, use it
2. **Name matching**: If a buffer refid matches a shader variable name, auto-bind
3. **Error**: If a required binding cannot be resolved, emit compile error

#### Example: Auto-Binding by Name

```wgsl
// initParticles shader - variable names ARE the binding contract
@group(0) @binding(0) var<storage, read_write> particles: array<Particle, 10000>;
@group(0) @binding(1) var<storage, read> velocityField: array<vec3f, 1024>;
@group(0) @binding(2) var<uniform> params: vec4u;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) { ... }
```

```
#buffer particles { size=initParticles.particles usage=[VERTEX STORAGE] }
#buffer velocityField { size=initParticles.velocityField usage=[STORAGE] }

#init resetParticles {
  shader=initParticles
  params=[42 0 0 0]
  // Auto-binds: particles → particles buffer (name match)
  //             velocityField → velocityField buffer (name match)
  //             params → internal params buffer (reserved name)
}
```

#### Example: Explicit Bindings (Different Names)

When buffer refids don't match shader variable names:

```wgsl
@group(0) @binding(0) var<storage, read_write> output: array<Particle, 10000>;
@group(0) @binding(1) var<storage, read> source: array<vec3f, 1024>;
```

```
#buffer particleBuffer { size=320000 usage=[VERTEX STORAGE] }
#buffer fieldBuffer { size=12288 usage=[STORAGE] }

#init resetParticles {
  shader=initParticles
  bindings={
    output=particleBuffer    // Explicit: shader var 'output' → buffer 'particleBuffer'
    source=fieldBuffer       // Explicit: shader var 'source' → buffer 'fieldBuffer'
  }
  params=[42 0 0 0]
}
```

#### Example: Multiple Outputs (Ping-Pong Init)

Initialize both buffers in a ping-pong pair:

```wgsl
@group(0) @binding(0) var<storage, read_write> particlesA: array<Particle, 10000>;
@group(0) @binding(1) var<storage, read_write> particlesB: array<Particle, 10000>;
```

```
#buffer particles { size=initBoth.particlesA usage=[VERTEX STORAGE] pool=2 }

#init initBoth {
  shader=initBothShader
  bindings={
    particlesA=particles[0]   // First pool buffer
    particlesB=particles[1]   // Second pool buffer
  }
}
```

### Reserved Binding Names

| Name | Purpose | Auto-Created |
|------|---------|--------------|
| `params` | 16-byte uniform with user params | Yes, if shader declares it |

When the shader declares `var<uniform> params: vec4u`, the compiler automatically
creates a 16-byte uniform buffer and binds it. The `params=[...]` property fills it.

### Reflection-Based Bind Group Generation

The compiler generates bind groups from shader reflection:

```zig
fn emitInit(self: *Emitter, init_node: Node) !void {
    const shader_source = self.getShaderSource(init_node.shader);

    // Use miniray reflection to get all bindings
    const reflect = try miniray_ffi.reflectFfi(shader_source);
    defer reflect.deinit();

    const bindings = parseBindings(reflect.json);

    // Resolve each binding to a buffer
    for (bindings) |binding| {
        const buffer_id = if (explicit_bindings.get(binding.name)) |explicit|
            self.resolveBufferRef(explicit)
        else if (self.buffer_ids.get(binding.name)) |auto|
            auto  // Name match
        else if (std.mem.eql(u8, binding.name, "params"))
            self.createParamsBuffer()  // Reserved
        else
            return error.UnresolvedBinding;

        try self.bind_group_entries.append(.{
            .binding = binding.binding,
            .buffer = buffer_id,
        });
    }

    // Create bind group with resolved entries
    try self.emitCreateBindGroup(bind_group_id, pipeline_id, self.bind_group_entries.items);
}
```

### Auto-Dispatch Calculation

Dispatch is calculated from:

1. **Buffer size** (in bytes)
2. **Element size** (from reflected array type)
3. **Workgroup size** (from `@workgroup_size` in shader)

```
element_count = buffer_size / element_size
workgroup_count = ceil(element_count / workgroup_size)
dispatch = [workgroup_count, 1, 1]
```

For 2D/3D dispatch (e.g., textures), use explicit `dispatch=` override:

```
#init initHeightmap {
  buffer=heightmap
  shader=initHeightmapShader
  params=[128 128 12345 6]     // width, height, seed, octaves
  dispatch=[16 16 1]           // 128/8 = 16 workgroups per dimension
}
```

---

## Frame Integration

### `init=` vs `perform=`

| Property | When It Runs | Use Case |
|----------|--------------|----------|
| `init=` | Once before first frame | One-time setup |
| `perform=` | Every frame | Per-frame updates, animations |

### Examples

```
// One-time initialization
#frame main {
  init=[resetParticles loadTextures]
  perform=[updatePass renderPass]
}

// Per-frame re-initialization (e.g., reset on time loop)
#frame main {
  perform=[resetParticles updatePass renderPass]
}

// Mixed: some init once, some per-frame
#frame main {
  init=[loadTextures]
  perform=[resetParticles updatePass renderPass]
}
```

---

## When to Use What

| Need | Approach | Example |
|------|----------|---------|
| Static mesh (cube, sphere) | `#init` with init shader | Cube/sphere generators |
| Random/noise init (once) | `#init` in `init=` | Particles, heightmaps |
| Random/noise init (per-frame) | `#init` in `perform=` | Animated noise |
| Per-frame simulation | Regular `#computePass` | Boids, physics |
| Deterministic results | WASM-in-WASM | Reproducible seeds |
| External library | WASM-in-WASM | Rapier physics |

### Decision Tree

```
Need to initialize buffer data?
│
├─ Does it need to be deterministic/reproducible?
│  └─ YES → Use WASM-in-WASM (#wasmCall)
│
├─ Using an external WASM library?
│  └─ YES → Use WASM-in-WASM (#wasmCall)
│
├─ One-time initialization?
│  └─ YES → Use #init in init=[]
│
└─ Per-frame dynamic init?
   └─ YES → Use #init in perform=[]
```

---

## WASM-in-WASM (Edge Cases)

The existing `#wasmCall` system remains for:

1. **Deterministic results** - GPU compute is non-deterministic
2. **Complex sequential algorithms** - Sorting, tree building
3. **External WASM libraries** - Physics engines, FFT, etc.

```
#wasmCall initPhysicsWorld {
  module={ url="rapier.wasm" }
  func="createWorld"
  args=[ canvas.width, canvas.height ]
  returns={ buffer=physicsState size=65536 }
}

#frame main {
  init=[initPhysicsWorld]   // Runs once
  perform=[simulatePass renderPass]
}
```

No changes needed - this already works.

---

## Opcodes to Remove

> **Important**: There are TWO opcode sets in PNGine:
> 1. **PNGB Bytecode** (`src/types/opcodes.zig`) - used in compiled `.pngb` files
> 2. **Command Buffer** (`src/executor/command_buffer.zig`) - used in runtime JS communication
>
> The JS `gpu.js` processes **Command Buffer** opcodes, NOT PNGB opcodes.
> The Zig dispatcher translates from PNGB to Command Buffer format.

### Command Buffer Opcodes (JS runtime - `command_buffer.zig`)

These 5 opcodes from `command_buffer.zig` become unnecessary:

| Opcode | Name | Replacement |
|--------|------|-------------|
| 0x40 | create_typed_array | Not needed |
| 0x41 | fill_random | `#init` |
| 0x42 | fill_expression | `#init` |
| 0x43 | fill_constant | `#init` |
| 0x44 | write_buffer_from_array | Not needed |

### PNGB Bytecode Opcodes (compiler - `types/opcodes.zig`)

These 7 opcodes from `types/opcodes.zig` can also be deprecated:

| Opcode | Name | Replacement |
|--------|------|-------------|
| 0x50 | create_typed_array | Not needed |
| 0x51 | fill_constant | `#init` |
| 0x52 | fill_random | `#init` |
| 0x53 | fill_linear | `#init` |
| 0x54 | fill_element_index | `#init` |
| 0x55 | fill_expression | `#init` |
| 0x29 | write_buffer_from_array | Not needed |

### Size Impact

**Executor WASM**: -3-5KB (remove data_gen.zig)
**JS Bundle**: -1KB (remove gpu.js lines 407-481, ~65 lines)
**Command buffer**: 5 fewer opcodes to implement

---

## Implementation Plan

### Phase 1: WGSL Reflection for Auto-Sizing

**Dependencies**: miniray 0.3.0+ (rebuild: `cd ../../miniray && make lib`)

**Key Feature**: miniray 0.3.0 provides full WGSL-spec memory layout computation via `miniray_reflect()`.
This eliminates the need to write custom reflection - we get struct sizes, array strides, and field
offsets that follow WGSL alignment rules (e.g., vec3 has align=16, size=12).

**Files to modify**:

1. `src/reflect/miniray_ffi.zig` - Already calls `miniray_reflect()`, parses JSON result
2. `src/dsl/Analyzer.zig` - Resolve `size=shader.var` references using reflection
3. `src/dsl/Parser.zig` - Parse dotted identifier syntax

**Miniray Reflection Output** (from `miniray_reflect`):

```json
{
  "bindings": [{
    "group": 0, "binding": 0,
    "name": "particles", "addressSpace": "storage",
    "type": "array<Particle, 10000>",
    "layout": { "size": 320000, "alignment": 16 },
    "array": {
      "elementCount": 10000,
      "elementStride": 32,
      "elementType": "Particle",
      "elementLayout": { "size": 32, "alignment": 16, "fields": [...] }
    }
  }],
  "structs": { "Particle": { "size": 32, "alignment": 16, "fields": [...] } },
  "entryPoints": [{ "name": "main", "stage": "compute", "workgroupSize": [64, 1, 1] }]
}
```

**Reflection API** (using existing miniray FFI):

```zig
// In src/reflect/miniray_ffi.zig - already exists
pub fn reflectFfi(source: []const u8) Error!FfiResult;

// New helper to extract variable info from JSON
pub fn getBindingInfo(json: []const u8, var_name: []const u8) ?BindingInfo;

const BindingInfo = struct {
    byte_size: u32,           // layout.size
    element_count: ?u32,      // array.elementCount (null for non-arrays)
    element_stride: ?u32,     // array.elementStride
    workgroup_size: [3]u32,   // From entryPoints (for dispatch calc)
};
```

**Deliverable**: `size=shaderName.varName` resolves at compile time using miniray reflection.

### Phase 2: Add `#init` Macro

**Files to modify**:

1. `src/dsl/Token.zig` - Add `macro_init` to macro_keywords
2. `src/dsl/Ast.zig` - Add `macro_init` to Node.Tag
3. `src/dsl/Parser.zig` - Handle `#init` in parseMacro
4. `src/dsl/Analyzer.zig` - Add `init` symbol table, validate references

**Deliverable**: `#init` parses and validates.

### Phase 3: Emit `#init` to Bytecode (with Auto-Binding)

**Files to modify**:

1. `src/dsl/Emitter.zig` - Emit compute pipeline, bind group, dispatch
2. `src/reflect/` - Add JSON parsing helpers for binding extraction

**Emitter logic** (uses reflection for auto-binding):

```zig
fn emitInit(self: *Emitter, init_node: Node) !void {
    const shader_name = getProperty(init_node, "shader");
    const explicit_bindings = getProperty(init_node, "bindings"); // Optional
    const params = getProperty(init_node, "params") orelse default_params;
    const shader_source = self.getShaderSource(shader_name);

    // 1. Reflect shader to get all bindings
    var reflect_result = try miniray_ffi.reflectFfi(shader_source);
    defer reflect_result.deinit();
    const shader_bindings = try parseBindingsJson(reflect_result.json);

    // 2. Resolve each binding (explicit > name-match > reserved > error)
    var bind_group_entries = std.ArrayList(BindGroupEntry).init(self.allocator);
    var params_buffer_id: ?u32 = null;
    var dispatch_source_binding: ?BindingInfo = null;

    for (shader_bindings) |binding| {
        const buffer_id: u32 = blk: {
            // Check explicit bindings first
            if (explicit_bindings) |explicit| {
                if (explicit.get(binding.name)) |ref| {
                    break :blk try self.resolveBufferRef(ref);
                }
            }
            // Try name matching
            if (self.buffer_ids.get(binding.name)) |id| {
                break :blk id;
            }
            // Reserved: params
            if (std.mem.eql(u8, binding.name, "params")) {
                params_buffer_id = self.allocateInternalBuffer();
                try self.emitCreateBuffer(params_buffer_id.?, 16, .uniform_copy_dst);
                break :blk params_buffer_id.?;
            }
            // Unresolved
            return self.emitError("Unresolved binding '{s}' in #init", .{binding.name});
        };

        try bind_group_entries.append(.{
            .binding = binding.binding,
            .buffer = buffer_id,
        });

        // Use first storage buffer for dispatch calculation
        if (dispatch_source_binding == null and binding.address_space == .storage) {
            dispatch_source_binding = binding;
        }
    }

    // 3. Create compute pipeline
    const shader_id = self.shader_ids.get(shader_name).?;
    const pipeline_id = self.allocateInternalPipeline();
    try self.emitCreateComputePipeline(pipeline_id, shader_id);

    // 4. Create bind group with resolved entries
    const bind_group_id = self.allocateInternalBindGroup();
    try self.emitCreateBindGroup(bind_group_id, pipeline_id, bind_group_entries.items);

    // 5. Calculate dispatch (from explicit override or reflection)
    const dispatch = if (getProperty(init_node, "dispatch")) |d|
        d
    else if (dispatch_source_binding) |binding|
        calculateDispatch(binding, shader_bindings.workgroup_size)
    else
        .{ 1, 1, 1 };

    // 6. Store for frame emission
    try self.init_operations.append(.{
        .params_buffer = params_buffer_id,
        .params = params,
        .pipeline = pipeline_id,
        .bind_group = bind_group_id,
        .dispatch = dispatch,
    });
}
```

**Deliverable**: `#init` generates correct bytecode with auto-binding support.

### Phase 4: Frame `init=` Support

**Files to modify**:

1. `src/dsl/Parser.zig` - Parse `init=` property in `#frame`
2. `src/dsl/Emitter.zig` - Emit init operations before frame loop

**Deliverable**: `init=[...]` runs once before first frame.

### Phase 5: Dynamic Params

**Files to modify**:

1. `src/dsl/Analyzer.zig` - Recognize runtime value identifiers
2. `src/dsl/Emitter.zig` - Emit runtime-resolved params

**Encoding**: Same as WasmArgType (0x01=canvas.width, 0x03=time.total, etc.)

**Deliverable**: `params=[time.total canvas.width 0 0]` works.

### Phase 6: Remove Data-Gen Opcodes

**Files to modify**:

1. **PNGB Bytecode** (`src/types/opcodes.zig`) - Mark 0x50-0x55, 0x29 as reserved
2. **Command Buffer** (`src/executor/command_buffer.zig`) - Remove 0x40-0x44 (create_typed_array, fill_*, write_buffer_from_array)
3. **Dispatcher** (`src/executor/dispatcher/data_gen.zig`) - Delete file
4. **JS Runtime** (`npm/pngine/src/gpu.js`) - Remove lines 407-481 (~65 lines, handles 0x40-0x44)

**Deliverable**: Leaner command buffer, smaller executor.

### Phase 7: Documentation

**Files to create/update**:

1. `CLAUDE.md` - Document `#init` and `size=shader.var`
2. `examples/particles_init.pngine` - Example using `#init`
3. `examples/dynamic_init.pngine` - Example with dynamic params

**Deliverable**: Clear documentation, working examples.

---

## Examples

### Particle System (Auto-Binding by Name)

```
#wgsl initParticles {
  value="
    struct Particle { pos: vec3f, vel: vec3f, life: f32, _pad: f32 }

    // Variable name 'particles' matches buffer name → auto-bound!
    @group(0) @binding(0) var<storage, read_write> particles: array<Particle, 10000>;
    @group(0) @binding(1) var<uniform> params: vec4u;  // Reserved name → auto-created

    fn pcg(state: ptr<function, u32>) -> f32 {
      *state = *state * 747796405u + 2891336453u;
      let word = ((*state >> ((*state >> 28u) + 4u)) ^ *state) * 277803737u;
      return f32((word >> 22u) ^ word) / 4294967295.0;
    }

    fn spherePoint(i: u32, n: u32) -> vec3f {
      let phi = (1.0 + sqrt(5.0)) / 2.0;
      let theta = 2.0 * 3.14159 * f32(i) / phi;
      let z = 1.0 - 2.0 * (f32(i) + 0.5) / f32(n);
      return vec3f(sqrt(1.0 - z*z) * cos(theta), sqrt(1.0 - z*z) * sin(theta), z);
    }

    @compute @workgroup_size(64)
    fn main(@builtin(global_invocation_id) id: vec3u) {
      if (id.x >= arrayLength(&particles)) { return; }
      var seed = params.x + id.x;

      let pos = spherePoint(id.x, arrayLength(&particles)) * 10.0;
      let vel = normalize(pos) * (0.5 + pcg(&seed) * 1.5);
      let life = pcg(&seed);

      particles[id.x] = Particle(pos, vel, life, 0.0);
    }
  "
}

#buffer particles {
  size=initParticles.particles  // Auto-size from shader reflection
  usage=[VERTEX STORAGE]
}

#init resetParticles {
  shader=initParticles          // Auto-binds: particles → particles buffer (name match)
  params=[42 0 0 0]             //             params → internal uniform (reserved)
}

#frame main {
  init=[resetParticles]
  perform=[updatePass renderPass]
}
```

### Heightmap with Dynamic Seed (Explicit Bindings)

```
#wgsl initHeightmap {
  value="
    // Variable name 'heightData' differs from buffer 'heightmap'
    @group(0) @binding(0) var<storage, read_write> heightData: array<f32, 16384>;  // 128x128
    @group(0) @binding(1) var<uniform> params: vec4u;  // seed, _, _, _

    // ... noise functions ...

    @compute @workgroup_size(8, 8)
    fn main(@builtin(global_invocation_id) id: vec3u) {
      let width = 128u;
      let height = 128u;
      if (id.x >= width || id.y >= height) { return; }
      let uv = vec2f(f32(id.x), f32(id.y)) / vec2f(f32(width), f32(height));
      heightData[id.y * width + id.x] = fbm(uv * 4.0 + f32(params.x) * 0.01, 6u);
    }
  "
}

#buffer heightmap {
  size=initHeightmap.heightData  // Auto-size from shader variable
  usage=[STORAGE]
}

#init animateHeightmap {
  shader=initHeightmap
  bindings={
    heightData=heightmap  // Explicit: shader var 'heightData' → buffer 'heightmap'
  }
  params=[time.total 0 0 0]       // Dynamic param: seed changes each frame!
  dispatch=[16 16 1]              // 128/8 = 16 workgroups per dimension
}

#frame main {
  perform=[animateHeightmap renderPass]  // Re-generates every frame
}
```

---

## What We're NOT Doing

1. **No template library** - Complexity without clear benefit
2. **No WASM templates** - Compute shaders handle most cases
3. **No expression VM** - Removed, use compute shaders
4. **No typed array opcodes** - Removed, use `#init`
5. **No compile-time generators** - Use `#init` with GPU compute instead

---

## Success Criteria

1. `#init` macro works for GPU initialization
2. `size=shader.var` auto-sizing works via reflection
3. **Auto-binding**: buffers auto-bound to shader variables by name match
4. **Explicit bindings**: `bindings={ varName=bufferRefId }` for custom mapping
5. **Pool buffer access**: `bufferRefId[0]` syntax for ping-pong init
6. Dynamic params (`time.total`, etc.) work in `#init`
7. `init=` runs once, `perform=` runs every frame
8. Data-gen opcodes removed:
   - Command buffer: 0x40-0x44
   - PNGB bytecode: 0x50-0x55, 0x29
9. Executor 3-5KB smaller
10. Examples updated and documented
11. All tests pass

---

## Work Log

### Current Status

**Phase**: Not started

### Log Entries

#### 2025-12-28: Auto-Binding via Reflection

- Removed `buffer=` property from `#init` macro (was single-buffer limitation)
- Added **auto-binding by name**: shader variable names matched to buffer refids
- Added **explicit bindings**: `bindings={ varName=bufferRefId }` for custom mapping
- Added **pool buffer access**: `bufferRefId[0]` syntax for initializing ping-pong pairs
- Added `dispatch=` override property for 2D/3D compute shaders
- Updated examples to demonstrate both auto-binding and explicit binding patterns
- Binding resolution order: explicit > name-match > reserved (`params`) > error
- Leverages miniray 0.3.0 reflection to extract all `@group/@binding` declarations
- Removed deprecated `$namespace.name` syntax - use direct refids exclusively
- Removed `fill=` compile-time generators - use `#init` with GPU compute instead

#### 2025-12-28: Miniray 0.3.0 Integration

- Updated plan to use miniray 0.3.0 reflection features
- Key new capabilities from miniray 0.3.0:
  - **WGSL-spec memory layout**: struct sizes, array strides, field offsets with proper alignment
  - **Array metadata**: `elementCount`, `elementStride`, `elementType`, `elementLayout`
  - **Entry point info**: `workgroupSize` for auto-dispatch calculation
- Phase 1 now leverages `miniray_reflect()` FFI instead of custom reflection
- Reflection output includes all data needed for `size=shader.var` auto-sizing
- Rebuild miniray: `cd ../../miniray && make lib`

#### 2025-12-28: Opcode Documentation Fix

- Clarified the TWO opcode sets in PNGine:
  - **PNGB Bytecode** (`types/opcodes.zig`): 0x50-0x55 for data-gen, used in `.pngb` files
  - **Command Buffer** (`command_buffer.zig`): 0x40-0x44 for data-gen, used by JS runtime
- The JS `gpu.js` correctly matches `command_buffer.zig`, NOT `types/opcodes.zig`
- Updated Phase 6 to reference both opcode sets correctly
- Fixed size impact estimate: JS savings ~1KB (65 lines), not 2KB

#### 2025-12-28: Plan Revised (v2)

- Changed from `initCompute` property on `#buffer` to separate `#init` macro
- Added auto-sizing via shader reflection (`size=shader.var`)
- Added dynamic params support for per-frame initialization
- Added `init=` property to `#frame` for one-time setup
- Kept `#buffer` clean and consistent with WebGPU createBuffer
- Expanded to 7 phases for clearer implementation path

#### Phase Checklist

- [ ] Phase 1: WGSL reflection for auto-sizing
- [ ] Phase 2: Add `#init` macro to DSL
- [ ] Phase 3: Emit `#init` to bytecode
- [ ] Phase 4: Frame `init=` support
- [ ] Phase 5: Dynamic params
- [x] Phase 6: Remove data-gen opcodes
- [ ] Phase 7: Documentation and examples
