# LLM Runtime Testing Plan

## Problem Statement

When developing PNGine shaders, runtime errors currently require:
1. Running in browser
2. Opening DevTools console
3. Copy-pasting error output
4. Pasting into a file for LLM to read
5. LLM analyzes and suggests fixes

This loop is slow, error-prone, and breaks flow. Most runtime errors occur in the
command buffer layer - a well-defined abstraction between the WASM executor and
the GPU. We can validate this layer natively without a browser.

## Key Insight: The Command Buffer is the Contract

```
┌─────────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│  WASM Executor      │ ──► │  Command Buffer      │ ──► │  JS/GPU         │
│  (deterministic)    │     │  (inspectable)       │     │  (needs browser)│
└─────────────────────┘     └──────────────────────┘     └─────────────────┘
         │                           │                            │
    Runs in wasm3            Can validate natively         Can't test natively
```

The command buffer contains:
- 53 fixed-format commands (CREATE_BUFFER, DRAW, DISPATCH, etc.)
- Resource IDs and references
- Pointers to WGSL code, vertex data, uniforms
- Complete execution trace

If the command buffer is valid, the JS/GPU side will work (barring GPU-specific
limits and WGSL compilation errors, which we can partially validate too).

## What We Can Validate Natively

### 1. Resource Existence (Critical)
- `SET_PIPELINE` references a created pipeline
- `SET_BIND_GROUP` references a created bind group
- `SET_VERTEX_BUFFER` references a created buffer
- `WRITE_BUFFER` references a created buffer

### 2. Resource Creation Order (Critical)
- Shader modules created before pipelines
- Buffers created before bind groups that reference them
- Pipelines created before render/compute passes use them

### 3. State Machine Violations (Critical)
- `DRAW` only inside active render pass
- `DISPATCH` only inside active compute pass
- `SET_PIPELINE` before `DRAW`/`DISPATCH`
- `END_PASS` matches `BEGIN_*_PASS`
- No nested passes

### 4. Memory Bounds (Critical)
- Data pointers within WASM memory (0-2MB)
- `ptr + len` doesn't overflow
- String pointers are null-terminated or length-bounded

### 5. Descriptor Validation (Important)
- Valid texture formats (rgba8unorm, etc.)
- Valid buffer usage flags
- Valid blend modes, compare functions

### 6. WGSL Analysis (Helpful)
- Extract and display shader code
- Detect missing entry points referenced by pipeline
- Parse binding declarations for layout validation
- Warn about potential issues (large arrays, complex control flow)

### 7. Usage Pattern Warnings (Nice to Have)
- Unused resources (created but never referenced)
- Redundant state sets (SET_PIPELINE twice in a row)
- Suboptimal patterns (many small WRITE_BUFFER vs one large)

## What Still Requires Browser Testing

1. **WGSL Compilation Errors** - GPU validates shader syntax/semantics
2. **GPU Limits** - Max texture size, max bind groups, max uniform size
3. **Visual Correctness** - Actual rendered output
4. **Performance** - Frame timing, GPU occupancy
5. **Platform Quirks** - Browser/driver-specific behavior

## Symptom-Based Diagnostics

When the user describes visual issues, the validator can look for likely causes:

### "Canvas is completely black"
```json
{
  "symptom": "black_screen",
  "checks": [
    {"check": "has_draw_command", "result": false, "severity": "error",
     "message": "No DRAW commands in frame - nothing is rendered"},
    {"check": "pipeline_before_draw", "result": false, "severity": "error",
     "message": "SET_PIPELINE missing before DRAW"},
    {"check": "vertex_count_nonzero", "result": false, "severity": "error",
     "message": "DRAW vertex_count is 0"},
    {"check": "clear_color", "result": {"r": 0, "g": 0, "b": 0, "a": 1},
     "message": "Clear color is black - if shader fails, you'll see black"},
    {"check": "vertex_buffer_bound", "result": false, "severity": "warning",
     "message": "No vertex buffer bound - vertices may be at origin"},
    {"check": "uniforms_written", "result": false, "severity": "warning",
     "message": "No WRITE_BUFFER for uniforms - shader may use zero values"}
  ]
}
```

### "Wrong colors / unexpected colors"
```json
{
  "symptom": "wrong_colors",
  "checks": [
    {"check": "clear_color", "result": {"r": 1, "g": 0, "b": 0, "a": 1},
     "message": "Clear color is red - check if this is intended"},
    {"check": "blend_state", "result": "none",
     "message": "No blend state - colors will overwrite, not blend"},
    {"check": "color_format", "result": "bgra8unorm",
     "message": "Using BGRA format - ensure shader outputs in correct order"},
    {"check": "texture_format_mismatch", "result": true,
     "message": "Texture format (rgba8unorm) differs from render target (bgra8unorm)"}
  ]
}
```

### "Wrong blending / transparency issues"
```json
{
  "symptom": "blend_issues",
  "checks": [
    {"check": "blend_enabled", "result": false, "severity": "error",
     "message": "Blend not enabled in pipeline - alpha will be ignored"},
    {"check": "blend_src_factor", "result": "one",
     "message": "Blend srcFactor=one - not using alpha for blending"},
    {"check": "blend_dst_factor", "result": "zero",
     "message": "Blend dstFactor=zero - background completely replaced"},
    {"check": "alpha_component", "result": "missing",
     "message": "Pipeline has no alpha blend component - only RGB blended"},
    {"check": "premultiplied_alpha", "result": "likely_issue",
     "message": "srcFactor=one suggests premultiplied alpha but texture may not be"}
  ]
}
```

### "Nothing renders / fully transparent"
```json
{
  "symptom": "transparent_output",
  "checks": [
    {"check": "store_op", "result": "discard", "severity": "error",
     "message": "storeOp is 'discard' - rendered content is thrown away"},
    {"check": "alpha_in_clear", "result": 0, "severity": "error",
     "message": "Clear alpha is 0 - canvas starts fully transparent"},
    {"check": "fragment_outputs_alpha", "result": "unknown",
     "message": "Check shader outputs alpha (location(0) should be vec4)"},
    {"check": "write_mask", "result": "rgb_only",
     "message": "Write mask excludes alpha - alpha channel not written"}
  ]
}
```

### "Flickering / strobing"
```json
{
  "symptom": "flickering",
  "checks": [
    {"check": "ping_pong_offsets", "result": "both_zero", "severity": "error",
     "message": "Both ping-pong offsets are 0 - reading and writing same buffer"},
    {"check": "multiple_submits", "result": 2, "severity": "warning",
     "message": "Multiple SUBMIT commands per frame - may cause sync issues"},
    {"check": "frame_counter_usage", "result": false,
     "message": "Frame counter not used in buffer selection - no animation"}
  ]
}
```

### "Geometry wrong / distorted"
```json
{
  "symptom": "geometry_issues",
  "checks": [
    {"check": "vertex_buffer_size", "result": 36,
     "message": "Vertex buffer is 36 bytes - enough for 3 vec3 positions (triangle)"},
    {"check": "vertex_stride", "result": 12,
     "message": "Vertex stride is 12 bytes (vec3) - check if format matches"},
    {"check": "index_buffer_bound", "result": false,
     "message": "No index buffer - using non-indexed draw"},
    {"check": "uniform_buffer_size", "result": 64,
     "message": "Uniform buffer is 64 bytes - check if MVP matrix fits (64 bytes for mat4x4)"},
    {"check": "aspect_ratio_uniform", "result": "not_found",
     "message": "No aspect ratio in uniforms - geometry may be stretched"}
  ]
}
```

## Missing Operations Detection

The validator checks for operations that should exist but don't:

### Required for Rendering
| Missing | Severity | Message |
|---------|----------|---------|
| `CREATE_SHADER` | Error | No shader module created - can't create pipeline |
| `CREATE_RENDER_PIPELINE` | Error | No render pipeline - can't draw |
| `BEGIN_RENDER_PASS` | Error | No render pass - draw commands have no effect |
| `SET_PIPELINE` | Error | Pipeline not set - GPU doesn't know how to draw |
| `DRAW` or `DRAW_INDEXED` | Error | No draw command - nothing rendered |
| `END_PASS` | Error | Render pass not ended - results not flushed |
| `SUBMIT` | Error | No submit - command buffer not executed |

### Required for Compute
| Missing | Severity | Message |
|---------|----------|---------|
| `CREATE_COMPUTE_PIPELINE` | Error | No compute pipeline - can't dispatch |
| `BEGIN_COMPUTE_PASS` | Error | No compute pass - dispatch has no effect |
| `DISPATCH` | Error | No dispatch command - compute shader not run |

### Expected but Missing (Warnings)
| Missing | Context | Message |
|---------|---------|---------|
| `WRITE_BUFFER` | Has uniform buffer | Uniform buffer created but never written - using zeros |
| `SET_BIND_GROUP` | Has bind group | Bind group created but never bound - resources not accessible |
| `SET_VERTEX_BUFFER` | Pipeline expects vertices | Pipeline has vertex inputs but no buffer bound |
| `WRITE_TIME_UNIFORM` | Animation shader | No time uniform written - shader won't animate |

## Parameter Validation

Check if parameters make sense for common patterns:

### Buffer Sizes
```json
{
  "check": "buffer_sizes",
  "issues": [
    {"buffer_id": 0, "size": 16, "usage": "UNIFORM",
     "message": "16 bytes only fits 4 floats - typical uniform needs 64+ (mat4)"},
    {"buffer_id": 1, "size": 36, "usage": "VERTEX",
     "message": "36 bytes = 3 vertices × 12 bytes - only a single triangle"},
    {"buffer_id": 2, "size": 0, "usage": "STORAGE",
     "severity": "error", "message": "Zero-size buffer will fail on GPU"}
  ]
}
```

### Draw Parameters
```json
{
  "check": "draw_params",
  "issues": [
    {"vertex_count": 0, "severity": "error",
     "message": "Drawing 0 vertices - nothing will render"},
    {"vertex_count": 1, "severity": "warning",
     "message": "Drawing 1 vertex - only valid for point topology"},
    {"vertex_count": 2, "severity": "warning",
     "message": "Drawing 2 vertices - only valid for line topology"},
    {"instance_count": 0, "severity": "error",
     "message": "Drawing 0 instances - nothing will render"},
    {"first_vertex": 1000000, "buffer_size": 1024, "severity": "error",
     "message": "first_vertex exceeds buffer capacity"}
  ]
}
```

### Dispatch Parameters
```json
{
  "check": "dispatch_params",
  "issues": [
    {"workgroups": [0, 1, 1], "severity": "error",
     "message": "Dispatching 0 workgroups on X - compute shader won't run"},
    {"workgroups": [65536, 1, 1], "severity": "warning",
     "message": "65536 workgroups exceeds common GPU limit (65535)"},
    {"total_invocations": 16777216, "severity": "warning",
     "message": "16M invocations - may be slow or hit limits"}
  ]
}
```

### Render Pass Configuration
```json
{
  "check": "render_pass",
  "issues": [
    {"load_op": "load", "clear_value": "set", "severity": "warning",
     "message": "loadOp=load but clearValue set - clearValue will be ignored"},
    {"store_op": "discard", "severity": "warning",
     "message": "storeOp=discard - rendered content won't be visible"},
    {"depth_enabled": true, "depth_buffer": "none", "severity": "error",
     "message": "Depth test enabled but no depth buffer attached"}
  ]
}
```

## User Context Integration

The CLI accepts user-provided context for targeted diagnostics:

```bash
# User describes the problem
pngine validate shader.pngine --json --symptom "black screen"
pngine validate shader.pngine --json --symptom "wrong colors"
pngine validate shader.pngine --json --symptom "flickering"
pngine validate shader.pngine --json --symptom "nothing renders"

# Multiple symptoms
pngine validate shader.pngine --json --symptom "black screen" --symptom "no errors in console"

# Free-form description (LLM can parse this)
pngine validate shader.pngine --json --describe "triangle should be red but it's blue"
```

### Output with Context
```json
{
  "status": "warning",
  "user_symptom": "black screen",
  "likely_causes": [
    {
      "probability": "high",
      "cause": "No DRAW command in frame",
      "evidence": "Command buffer has 15 commands but no DRAW",
      "fix": "Add draw=3 to your #renderPass or check frame.perform includes the pass"
    },
    {
      "probability": "medium",
      "cause": "Vertex buffer not written",
      "evidence": "Buffer 0 (VERTEX) created but no WRITE_BUFFER for it",
      "fix": "Add vertex data to your shader or use data= in #buffer"
    }
  ],
  "full_diagnosis": { ... }  // Complete validation results
}
```

## Common Patterns Database

The validator knows about common shader patterns and can detect mismatches:

### Full-Screen Quad Pattern
Expected: 6 vertices (2 triangles), no vertex buffer (generated in shader)
```json
{
  "pattern": "fullscreen_quad",
  "expected": {"vertex_count": 6, "vertex_buffer": "none"},
  "actual": {"vertex_count": 3, "vertex_buffer": "none"},
  "message": "Looks like fullscreen quad but only 3 vertices - need 6 for 2 triangles"
}
```

### Instanced Rendering Pattern
Expected: Low vertex count, high instance count, instance buffer
```json
{
  "pattern": "instanced",
  "expected": {"instance_count": ">1", "instance_buffer": "present"},
  "actual": {"instance_count": 1000, "instance_buffer": "none"},
  "message": "High instance count but no instance buffer - all instances at same position"
}
```

### Ping-Pong Compute Pattern
Expected: 2 buffers, alternating bind groups
```json
{
  "pattern": "ping_pong",
  "expected": {"buffer_pool": 2, "bind_group_pool": 2},
  "actual": {"buffer_pool": 2, "bind_group_pool": 1},
  "message": "Buffer has pool=2 but bind group doesn't - ping-pong won't alternate"
}
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         LLM Testing Pipeline                                 │
│                                                                              │
│   pngine validate shader.pngine --json                                      │
│                                                                              │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐  │
│   │  Compiler   │───►│  PNGB       │───►│  wasm3      │───►│  Validator  │  │
│   │  (Zig)      │    │  Bytecode   │    │  Executor   │    │  (Zig)      │  │
│   └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘  │
│                                               │                    │         │
│                                               ▼                    ▼         │
│                                        ┌─────────────┐     ┌─────────────┐  │
│                                        │  Command    │────►│  JSON       │  │
│                                        │  Buffer     │     │  Report     │  │
│                                        └─────────────┘     └─────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Component: wasm3 Integration (`src/runtime/wasm3_runner.zig`)

```zig
const Wasm3Runner = struct {
    runtime: *wasm3.Runtime,
    module: *wasm3.Module,
    memory: []u8,

    // Memory layout (matches wasm_entry.zig)
    const BYTECODE_OFFSET = 0x00000000;
    const DATA_OFFSET = 0x00040000;
    const COMMAND_OFFSET = 0x000C0000;

    pub fn init(wasm_bytes: []const u8) !Wasm3Runner { ... }
    pub fn loadBytecode(self: *Wasm3Runner, pngb: []const u8) !void { ... }
    pub fn callInit(self: *Wasm3Runner) !void { ... }
    pub fn callFrame(self: *Wasm3Runner, time: f32, w: u32, h: u32) !void { ... }
    pub fn getCommandBuffer(self: *Wasm3Runner) []const u8 { ... }
    pub fn getMemory(self: *Wasm3Runner) []const u8 { ... }
};
```

### Component: Command Buffer Parser (`src/runtime/cmd_parser.zig`)

```zig
const Command = union(enum) {
    create_buffer: struct { id: u16, size: u32, usage: u8 },
    create_shader: struct { id: u16, code_ptr: u32, code_len: u32 },
    create_render_pipeline: struct { id: u16, desc_ptr: u32, desc_len: u32 },
    begin_render_pass: struct { color_id: u16, load: u8, store: u8, depth_id: u16 },
    set_pipeline: struct { id: u16 },
    set_bind_group: struct { slot: u8, id: u16, offsets_ptr: u32, offsets_len: u32 },
    draw: struct { vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32 },
    dispatch: struct { x: u32, y: u32, z: u32 },
    end_pass: void,
    submit: void,
    // ... all 53 commands
};

const ParsedBuffer = struct {
    commands: []Command,
    command_offsets: []u32,  // Byte offset of each command for error reporting
};

pub fn parse(buffer: []const u8) !ParsedBuffer { ... }
```

### Component: Validator (`src/runtime/validator.zig`)

```zig
const ValidationError = struct {
    code: []const u8,           // "E001", "W001", etc.
    error_type: ErrorType,      // .missing_resource, .state_violation, etc.
    severity: Severity,         // .error, .warning
    message: []const u8,
    command_index: u32,
    command_name: []const u8,
    context: ?Context,
};

const ValidationResult = struct {
    status: enum { ok, warning, @"error" },
    errors: []ValidationError,
    warnings: []ValidationError,
    resources: ResourceSummary,
    commands: []CommandSummary,
    wgsl: ?WgslAnalysis,
};

pub fn validate(commands: []Command, memory: []const u8) !ValidationResult {
    var state = ValidationState{};

    for (commands, 0..) |cmd, i| {
        switch (cmd) {
            .create_buffer => |b| try state.trackBuffer(b.id, b.size, b.usage),
            .set_pipeline => |p| try state.checkPipelineExists(p.id, i),
            .draw => try state.checkInRenderPass(i),
            // ...
        }
    }

    return state.finalize();
}
```

### Component: JSON Output (`src/runtime/report.zig`)

```zig
pub fn writeJson(writer: anytype, result: ValidationResult, memory: []const u8) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"status\": \"{s}\",\n", .{@tagName(result.status)});

    // Errors
    try writer.writeAll("  \"errors\": [\n");
    for (result.errors) |err| {
        try writeError(writer, err);
    }
    try writer.writeAll("  ],\n");

    // Resources
    try writer.writeAll("  \"resources\": ");
    try writeResources(writer, result.resources);

    // Commands (optional, controlled by --verbose)
    // WGSL extraction (optional, controlled by --extract-wgsl)

    try writer.writeAll("}\n");
}
```

## CLI Interface

```bash
# Basic validation (human-readable output)
pngine validate shader.pngine

# JSON output for LLM consumption
pngine validate shader.pngine --json

# Verbose: include full command trace
pngine validate shader.pngine --json --verbose

# Extract WGSL code for separate analysis
pngine validate shader.pngine --json --extract-wgsl

# Validate specific frame time
pngine validate shader.pngine --json --time 2.5

# Multiple frames (for animation testing)
pngine validate shader.pngine --json --frames 0,1,2,10

# Pipe to file for LLM
pngine validate shader.pngine --json > validation.json
```

## JSON Output Schema

```typescript
interface ValidationReport {
  status: "ok" | "warning" | "error";
  summary: string;

  errors: Array<{
    code: string;           // E001, E002, etc.
    type: string;           // missing_resource, state_violation, etc.
    severity: "error";
    message: string;
    command_index: number;
    command: string;
    context: {
      [key: string]: any;   // Error-specific context
      suggestion?: string;  // Fix suggestion
    };
  }>;

  warnings: Array<{
    code: string;           // W001, W002, etc.
    type: string;
    severity: "warning";
    message: string;
    command_index: number;
    context: object;
  }>;

  resources: {
    buffers: Array<{id: number, size: number, usage: string, created_at: number}>;
    textures: Array<{id: number, format: string, size: [number, number], created_at: number}>;
    pipelines: Array<{id: number, type: "render" | "compute", created_at: number}>;
    bind_groups: Array<{id: number, created_at: number}>;
    shaders: Array<{id: number, wgsl_length: number, created_at: number}>;
  };

  // Only with --verbose
  commands?: Array<{
    index: number;
    cmd: string;
    args: object;
  }>;

  // Only with --extract-wgsl
  wgsl?: {
    [shader_id: string]: {
      source: string;
      entry_points?: string[];
      bindings?: Array<{group: number, binding: number, type: string}>;
    };
  };

  memory: {
    bytecode_size: number;
    data_section_size: number;
    command_buffer_size: number;
  };
}
```

## Initialization & First Frame Inspection

A key debugging capability is seeing exactly what happens during initialization (resource
creation) and the first frame (runtime execution). This allows LLMs to reason about:
- Which resources were created and their properties
- The exact sequence of GPU commands
- Missing or misconfigured resources

### Output Modes

```bash
# Show initialization only (resource creation)
pngine validate shader.pngine --json --phase init

# Show first frame only (runtime commands)
pngine validate shader.pngine --json --phase frame

# Show both (default for --verbose)
pngine validate shader.pngine --json --verbose
```

### Initialization Phase Output

The initialization phase shows all resource creation commands:

```json
{
  "phase": "init",
  "commands": [
    {
      "index": 0,
      "cmd": "CREATE_BUFFER",
      "id": 0,
      "args": {
        "size": 1024,
        "usage": ["VERTEX", "COPY_DST"],
        "usage_raw": 168
      },
      "analysis": {
        "capacity": "~85 vec3 vertices or ~64 vec4 vertices",
        "typical_use": "vertex data"
      }
    },
    {
      "index": 1,
      "cmd": "CREATE_BUFFER",
      "id": 1,
      "args": {
        "size": 64,
        "usage": ["UNIFORM", "COPY_DST"],
        "usage_raw": 72
      },
      "analysis": {
        "capacity": "1 mat4x4 or 16 floats",
        "typical_use": "transformation matrix or uniforms"
      }
    },
    {
      "index": 2,
      "cmd": "CREATE_SHADER",
      "id": 0,
      "args": {
        "wgsl_ptr": 262144,
        "wgsl_len": 423
      },
      "analysis": {
        "entry_points": ["vs_main", "fs_main"],
        "bindings": [
          {"group": 0, "binding": 0, "type": "uniform", "struct": "Uniforms"}
        ],
        "wgsl_preview": "@vertex fn vs_main(@location(0) pos: vec3f) -> @builtin..."
      }
    },
    {
      "index": 3,
      "cmd": "CREATE_RENDER_PIPELINE",
      "id": 0,
      "args": {
        "shader_id": 0,
        "vertex_entry": "vs_main",
        "fragment_entry": "fs_main",
        "topology": "triangle-list",
        "vertex_buffers": [
          {"slot": 0, "stride": 12, "attributes": [{"format": "float32x3", "offset": 0}]}
        ]
      },
      "analysis": {
        "vertex_format": "vec3f positions only",
        "blend_state": "none (opaque)",
        "depth_test": "disabled"
      }
    },
    {
      "index": 4,
      "cmd": "CREATE_BIND_GROUP",
      "id": 0,
      "args": {
        "layout_source": "auto_from_pipeline",
        "pipeline_id": 0,
        "entries": [
          {"binding": 0, "resource_type": "buffer", "buffer_id": 1, "offset": 0, "size": 64}
        ]
      }
    }
  ],
  "summary": {
    "buffers_created": 2,
    "shaders_created": 1,
    "pipelines_created": 1,
    "bind_groups_created": 1,
    "textures_created": 0,
    "samplers_created": 0,
    "total_buffer_memory": 1088,
    "total_commands": 5
  }
}
```

### First Frame Phase Output

The first frame shows runtime commands that execute each frame:

```json
{
  "phase": "frame",
  "frame_number": 0,
  "time": 0.0,
  "canvas_size": [512, 512],
  "commands": [
    {
      "index": 0,
      "cmd": "WRITE_BUFFER",
      "args": {
        "buffer_id": 1,
        "buffer_offset": 0,
        "data_ptr": 262568,
        "data_len": 16
      },
      "analysis": {
        "buffer_name": "uniforms (id=1)",
        "buffer_usage": ["UNIFORM", "COPY_DST"],
        "data_preview": "[0.0, 512.0, 512.0, 1.0]",
        "interpretation": "Likely: [time, width, height, aspect]"
      }
    },
    {
      "index": 1,
      "cmd": "BEGIN_RENDER_PASS",
      "args": {
        "color_attachment": {
          "view": "canvas_texture",
          "load_op": "clear",
          "store_op": "store",
          "clear_value": [0.0, 0.0, 0.0, 1.0]
        },
        "depth_attachment": null
      },
      "analysis": {
        "clears_to": "black (opaque)",
        "will_be_visible": true
      }
    },
    {
      "index": 2,
      "cmd": "SET_PIPELINE",
      "args": {
        "pipeline_id": 0
      },
      "analysis": {
        "pipeline_type": "render",
        "topology": "triangle-list",
        "shader_id": 0
      }
    },
    {
      "index": 3,
      "cmd": "SET_BIND_GROUP",
      "args": {
        "slot": 0,
        "bind_group_id": 0,
        "dynamic_offsets": []
      },
      "analysis": {
        "bindings": [
          {"binding": 0, "resource": "buffer 1 (uniforms)"}
        ]
      }
    },
    {
      "index": 4,
      "cmd": "SET_VERTEX_BUFFER",
      "args": {
        "slot": 0,
        "buffer_id": 0,
        "offset": 0,
        "size": 1024
      },
      "analysis": {
        "buffer_name": "vertex buffer (id=0)",
        "vertex_count_capacity": 85,
        "format": "vec3f"
      }
    },
    {
      "index": 5,
      "cmd": "DRAW",
      "args": {
        "vertex_count": 3,
        "instance_count": 1,
        "first_vertex": 0,
        "first_instance": 0
      },
      "analysis": {
        "draws": "1 triangle (3 vertices)",
        "instancing": "none"
      }
    },
    {
      "index": 6,
      "cmd": "END_PASS"
    },
    {
      "index": 7,
      "cmd": "SUBMIT"
    }
  ],
  "summary": {
    "render_passes": 1,
    "compute_passes": 0,
    "draw_calls": 1,
    "dispatch_calls": 0,
    "buffer_writes": 1,
    "total_vertices_drawn": 3,
    "total_instances_drawn": 1,
    "total_commands": 8
  }
}
```

### Combined Verbose Output

With `--verbose`, both phases are included:

```json
{
  "status": "ok",
  "input": "shader.pngine",

  "initialization": {
    "phase": "init",
    "commands": [...],
    "summary": {...}
  },

  "first_frame": {
    "phase": "frame",
    "frame_number": 0,
    "commands": [...],
    "summary": {...}
  },

  "validation": {
    "errors": [],
    "warnings": [
      {
        "code": "W006",
        "message": "Buffer 0 (VERTEX) created with 1024 bytes but only 36 bytes used (3 vertices × 12 bytes)"
      }
    ]
  },

  "resources": {
    "buffers": [
      {"id": 0, "size": 1024, "usage": ["VERTEX", "COPY_DST"], "written": false, "bound_in_frame": true},
      {"id": 1, "size": 64, "usage": ["UNIFORM", "COPY_DST"], "written": true, "bound_in_frame": true}
    ],
    "shaders": [
      {"id": 0, "wgsl_len": 423, "entry_points": ["vs_main", "fs_main"]}
    ],
    "pipelines": [
      {"id": 0, "type": "render", "shader_id": 0, "used_in_frame": true}
    ],
    "bind_groups": [
      {"id": 0, "pipeline_id": 0, "used_in_frame": true}
    ]
  }
}
```

### LLM Debugging with Phase Output

**Example: "Nothing renders but no errors"**

```bash
pngine validate shader.pngine --json --phase frame
```

LLM analyzes output:
```
Looking at first_frame.commands:
- BEGIN_RENDER_PASS: ✓ present
- SET_PIPELINE: ✓ present
- SET_BIND_GROUP: ✓ present
- SET_VERTEX_BUFFER: ✗ MISSING
- DRAW: ✓ present with vertex_count=3

Issue found: No SET_VERTEX_BUFFER before DRAW.
The pipeline expects vertex data but no buffer is bound.

Fix: In your #renderPass, add:
  vertexBuffers=[positionBuffer]
```

**Example: "Animation not updating"**

```bash
pngine validate shader.pngine --json --frames 0,1,2
```

LLM compares frames:
```
Comparing frame 0, 1, 2:

Frame 0: WRITE_BUFFER data=[0.0, 512, 512, 1.0]
Frame 1: WRITE_BUFFER data=[0.0, 512, 512, 1.0]
Frame 2: WRITE_BUFFER data=[0.0, 512, 512, 1.0]

Issue: Time value (first float) is always 0.0 across frames.
The time uniform isn't being updated.

Check: Is your #queue using data=pngineInputs?
The runtime should be passing different time values per frame.
```

**Example: "Compute simulation stuck"**

```bash
pngine validate boids.pngine --json --verbose
```

LLM examines init + frame:
```
Initialization shows:
- Buffer 0 created with pool=2 (ping-pong)
- BindGroup 0 created (reads buffer 0, offset 0)
- BindGroup 1 created (reads buffer 0, offset 0)  ← PROBLEM

Both bind groups read from the same buffer instance!
For ping-pong to work, they should reference different pool offsets.

In your #bindGroup definition, entries need:
  entries=[
    { binding=0 resource={ buffer=particles pingPong=0 } }  // Read from previous
    { binding=1 resource={ buffer=particles pingPong=1 } }  // Write to current
  ]
```

### Multi-Frame Comparison

Test multiple frames to catch animation/timing bugs:

```bash
pngine validate shader.pngine --json --frames 0,30,60 --time-step 0.016
```

Output includes diff analysis:

```json
{
  "frames": [
    {"frame": 0, "time": 0.0, "commands": [...], "summary": {...}},
    {"frame": 30, "time": 0.5, "commands": [...], "summary": {...}},
    {"frame": 60, "time": 1.0, "commands": [...], "summary": {...}}
  ],
  "frame_diff": {
    "static_commands": ["CREATE_*", "BEGIN_RENDER_PASS", "SET_PIPELINE", "DRAW", "END_PASS", "SUBMIT"],
    "varying_commands": ["WRITE_BUFFER"],
    "varying_data": {
      "buffer_1": {
        "frame_0": [0.0, 512, 512, 1.0],
        "frame_30": [0.5, 512, 512, 1.0],
        "frame_60": [1.0, 512, 512, 1.0],
        "interpretation": "time increasing correctly"
      }
    }
  }
}
```

## Error Codes

### Critical Errors (E0xx)
| Code | Type | Description |
|------|------|-------------|
| E001 | missing_resource | Reference to non-existent resource |
| E002 | state_violation | Command in wrong state (draw outside pass) |
| E003 | creation_order | Resource used before creation |
| E004 | memory_bounds | Pointer exceeds WASM memory |
| E005 | duplicate_id | Resource ID already in use |
| E006 | invalid_descriptor | Malformed descriptor data |
| E007 | pass_mismatch | END_PASS without matching BEGIN |
| E008 | nested_pass | BEGIN_PASS inside active pass |

### Warnings (W0xx)
| Code | Type | Description |
|------|------|-------------|
| W001 | unused_resource | Created but never used |
| W002 | redundant_state | Consecutive identical state sets |
| W003 | empty_pass | Pass with no draw/dispatch calls |
| W004 | large_buffer | Buffer > 16MB may fail on some GPUs |
| W005 | missing_entry | WGSL entry point not found (partial analysis) |

## Implementation Phases

### Phase 1: wasm3 Integration (2-3 days)
- [ ] Add wasm3 as build dependency (C library via build.zig.zon)
- [ ] Create `Wasm3Runner` wrapper in Zig (`src/runtime/wasm3.zig`)
- [ ] Implement memory read/write helpers
- [ ] Load embedded executor WASM
- [ ] Implement host functions for command buffer (no-op stubs)
- [ ] Test: call init(), verify no crash

### Phase 2: Command Buffer Parser (2 days)
- [ ] Port command definitions from `command_buffer.zig`
- [ ] Implement parser with all 53 commands
- [ ] Add offset tracking for error reporting
- [ ] Resource ID tracking (created/used)
- [ ] Unit tests with known command sequences

### Phase 3: Phase Output (1-2 days)
- [ ] Separate init commands from frame commands
- [ ] Add `--phase init|frame|both` flag
- [ ] JSON output for initialization phase
- [ ] JSON output for first frame phase
- [ ] Multi-frame support (`--frames 0,1,2`)

### Phase 4: Validator Core (2-3 days)
- [ ] State machine (pass nesting, pipeline state)
- [ ] Reference validation (all IDs exist)
- [ ] Memory bounds checking
- [ ] Symptom-based diagnosis (`--symptom`)
- [ ] Comprehensive test suite

### Phase 5: WGSL Analysis (1-2 days)
- [ ] Extract WGSL from memory pointers
- [ ] Parse entry point declarations
- [ ] Parse binding declarations
- [ ] Add to command analysis output

### Phase 6: CLI & Polish (1 day)
- [ ] Add `validate` subcommand to CLI
- [ ] Human-readable formatter (default)
- [ ] All flags (--json, --verbose, --phase, --strict, etc.)
- [ ] End-to-end tests with real .pngine files
- [ ] Documentation and examples

## Example LLM Workflow

### Before (Current)
```
User: "I'm getting an error in the browser"
User: [pastes 50 lines of console output]
LLM: [tries to parse unstructured text]
LLM: "I see the error is... let me check the code..."
[Multiple back-and-forth exchanges]
```

### After (With This System)
```
User: "Check my shader"
LLM: [runs] pngine validate shader.pngine --json
LLM: [parses JSON, sees E001: missing_resource for bind_group 5]
LLM: "Your shader references bind_group 5 but only creates bind_groups 0-3.
      Looking at your DSL, I see #bindGroup sim uses entries that reference
      buffer 'particles' with pool=2. You need to ensure the bind group IDs
      match. Here's the fix:

      [provides specific code change]"
```

## Future Extensions

### 1. Watch Mode
```bash
pngine validate shader.pngine --watch --json
```
Re-validates on file change, outputs incremental JSON updates.

### 2. Browser Integration
Embed validator in browser build, output to console as structured JSON
that browser extensions could parse.

### 3. IDE Integration
LSP server could use validator for real-time diagnostics.

### 4. Fuzzing Support
Generate random command buffers, validate they don't crash.
```bash
pngine validate --fuzz --iterations 10000
```

### 5. Comparison Mode
```bash
pngine validate shader.pngine --compare expected.json
```
Verify command buffer matches expected output (regression testing).

## Dependencies

- **wasm3**: MIT license, ~150KB, pure C, no dependencies
  - Already installed on system
  - Zig can link C libraries easily
  - Well-documented API

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| wasm3 API changes | Build breaks | Pin to specific version |
| Command format changes | Parser breaks | Version command buffer format |
| Large command buffers | Slow validation | Stream parsing, early exit on error |
| WGSL parsing complexity | Incomplete analysis | Focus on binding/entry point extraction only |

## Success Metrics

1. **Error Detection Rate**: >90% of runtime errors caught before browser
2. **False Positive Rate**: <5% warnings that aren't actionable
3. **Performance**: <100ms for typical shader validation
4. **LLM Usability**: JSON parseable without special prompting

## Edge Cases & Error Handling

### WASM Validation Failures
If the executor WASM itself is malformed:
```json
{
  "status": "error",
  "phase": "wasm_load",
  "errors": [{
    "code": "E100",
    "type": "wasm_validation",
    "message": "WASM module validation failed: invalid function signature at offset 0x1234"
  }]
}
```

### Executor Panics
If the executor hits an assertion or unreachable:
```json
{
  "status": "error",
  "phase": "execution",
  "errors": [{
    "code": "E101",
    "type": "executor_panic",
    "message": "Executor panic during init(): assertion failed at dispatcher.zig:456",
    "partial_commands": [...],  // Commands emitted before crash
    "bytecode_pc": 127          // Last bytecode position
  }]
}
```

### Memory Exhaustion
If command buffer overflows:
```json
{
  "status": "error",
  "phase": "execution",
  "errors": [{
    "code": "E102",
    "type": "buffer_overflow",
    "message": "Command buffer overflow at command 847 (64KB limit)",
    "suggestion": "Shader may have too many resources. Consider reducing complexity."
  }]
}
```

## Minimal Viable Implementation

For immediate value, implement only these (2-3 days):

### MVP Scope
1. **wasm3 runner**: Load WASM, call init()/frame(), read command buffer
2. **Basic parser**: Parse all 53 commands to structured format
3. **Resource tracking**: Track created resources, validate references exist
4. **JSON output**: Dump commands, resources, and any errors found

This catches the most common error: "undefined resource X" - which accounts
for ~60% of runtime errors.

### MVP CLI
```bash
pngine validate shader.pngine --json
```

### MVP Output
```json
{
  "status": "ok",
  "command_count": 42,
  "resources": {
    "buffers": [0, 1, 2],
    "pipelines": [0],
    "bind_groups": [0, 1]
  },
  "commands": [
    {"cmd": "CREATE_BUFFER", "id": 0, "size": 1024},
    ...
  ]
}
```

Even without full validation, just seeing the command trace is valuable
for debugging. The LLM can spot issues like "bind_group 3 is used but
only 0,1 were created".

## Integration with Existing Tests

The validator can augment existing test patterns:

```zig
// In existing test
test "simple triangle produces valid commands" {
    const pngb = try compile("simple_triangle.pngine");

    // New: validate command buffer
    var runner = try Wasm3Runner.init(executor_wasm);
    try runner.loadBytecode(pngb);
    try runner.callInit();

    const result = try validate(runner.getCommandBuffer());
    try testing.expect(result.status == .ok);
    try testing.expect(result.resources.pipelines.len == 1);
}
```

This catches regressions that MockGPU might miss.

## Command Design

### Primary Command
```bash
pngine validate <input> [options]
```

### Why a Separate Command?
1. **Clear intent** - "I want to debug runtime behavior"
2. **Dedicated output** - JSON-focused, structured for tools/LLMs
3. **No latency impact** - Normal compile/render stays fast
4. **Extensible** - Room for `--symptom`, `--frames`, `--compare`

### Full CLI Specification

```bash
pngine validate <input.pngine|input.png> [options]

Options:
  --json                 Output JSON (default: human-readable)
  --verbose              Include full command trace (init + frame) in output
  --phase <phase>        Show specific phase only: "init", "frame", or "both"
                         init  = resource creation commands only
                         frame = first frame runtime commands only
                         both  = init + frame (same as --verbose)
  --symptom <desc>       Focus diagnosis on specific symptom
                         Predefined: "black", "colors", "blend", "flicker", "geometry"
  --describe <text>      Free-form problem description
  --frames <list>        Test multiple frames (default: 0)
                         Example: --frames 0,1,10,60
  --time <seconds>       Test at specific time (default: 0.0)
  --time-step <seconds>  Time between frames for --frames (default: 0.016)
  --size <WxH>           Canvas size for validation (default: 512x512)
  --strict               Exit code 1 on warnings (for CI)
  --extract-wgsl         Include WGSL source in output
  --quiet                Only output errors, no info

Examples:
  pngine validate shader.pngine
  pngine validate shader.pngine --json > report.json
  pngine validate shader.pngine --json --phase init    # Only resource creation
  pngine validate shader.pngine --json --phase frame   # Only first frame
  pngine validate shader.pngine --symptom black --json
  pngine validate shader.png --verbose --frames 0,30,60
  pngine validate shader.pngine --frames 0,1,2 --time-step 0.5  # Test at 0s, 0.5s, 1s
```

## LLM Integration

### How LLMs Use This

LLMs with shell access (Claude Code, Cursor, Copilot, etc.) can:

```
User: "My boids simulation shows all particles stuck in corner"

LLM thinking: This sounds like a compute/ping-pong issue
LLM executes: pngine validate boids.pngine --json --symptom "geometry"

JSON output shows:
{
  "likely_causes": [
    {
      "probability": "high",
      "cause": "Ping-pong buffer offset mismatch",
      "evidence": "bind_group 0 and 1 both read from buffer 0",
      "fix": "Check bindGroupsPoolOffsets in #computePass"
    }
  ]
}

LLM: "The simulation reads from the same buffer it writes to.
      In your #computePass, change:

        bindGroupsPoolOffsets=[0]
      to:
        bindGroupsPoolOffsets=[1]

      This makes the compute pass read from the previous frame's
      output instead of the current frame's input."
```

### LLM Prompt Template

For LLM systems that need explicit instructions:

```
When the user reports a visual issue with their PNGine shader:

1. Run: pngine validate <file> --json --symptom "<issue>"
   Map user descriptions to symptoms:
   - "black screen", "nothing shows" → --symptom "black"
   - "wrong color", "blue instead of red" → --symptom "colors"
   - "transparency broken", "blending wrong" → --symptom "blend"
   - "flickering", "strobing" → --symptom "flicker"
   - "stretched", "wrong position" → --symptom "geometry"

2. Parse the JSON output, focusing on:
   - "likely_causes" array (ranked by probability)
   - "errors" array (must fix)
   - "warnings" array (should review)

3. Provide specific fixes referencing the user's DSL code
```

### Discerning User Workflow

**During Development:**
```bash
# Quick sanity check before browser
pngine validate shader.pngine

# Output:
# ✓ Shader valid
# ✓ 1 render pipeline, 2 buffers, 1 bind group
# ✓ Frame emits 23 commands
# ⚠ Warning: Uniform buffer created but never written
```

**When Something's Wrong:**
```bash
# See what's actually being emitted
pngine validate shader.pngine --verbose

# Output includes full command trace:
# [0] CREATE_BUFFER id=0 size=1024 usage=VERTEX|COPY_DST
# [1] CREATE_BUFFER id=1 size=64 usage=UNIFORM|COPY_DST
# [2] CREATE_SHADER id=0 wgsl_len=423
# ...
# [18] DRAW vertices=3 instances=1
# [19] END_PASS
# [20] SUBMIT
```

**For CI/Automation:**
```bash
# Fail build on any issue
pngine validate shader.pngine --json --strict || exit 1

# Validate all shaders
for f in examples/*.pngine; do
  pngine validate "$f" --json >> validation-report.json
done
```

**Comparing Behavior:**
```bash
# Save known-good output
pngine validate shader.pngine --json > expected.json

# Later, check for regressions
pngine validate shader.pngine --json | diff expected.json -
```

## Implementation: wasm3-First Approach

### Why wasm3 from the Start?

1. **Tests actual WASM build** - Catches export issues, memory layout bugs
2. **Same code path as browser** - No divergence risk
3. **Already bundled** - CLI embeds executor WASM for `--embed-executor`
4. **wasm3 is simple** - ~150KB, pure C, MIT license, already installed

### Build Integration

```zig
// build.zig additions
const wasm3_dep = b.dependency("wasm3", .{});
cli_module.linkLibrary(wasm3_dep.artifact("wasm3"));
```

### wasm3 Wrapper (`src/runtime/wasm3.zig`)

```zig
const Wasm3 = struct {
    env: *m3.Environment,
    runtime: *m3.Runtime,
    module: *m3.Module,

    // Function pointers (cached after linking)
    fn_init: m3.Function,
    fn_frame: m3.Function,
    fn_get_cmd_ptr: m3.Function,
    fn_get_cmd_len: m3.Function,

    pub fn init(wasm_bytes: []const u8) !Wasm3 {
        const env = m3.m3_NewEnvironment() orelse return error.Wasm3Init;
        const runtime = m3.m3_NewRuntime(env, 64 * 1024, null) orelse return error.Wasm3Init;

        var module: *m3.Module = undefined;
        if (m3.m3_ParseModule(env, &module, wasm_bytes.ptr, wasm_bytes.len) != null)
            return error.Wasm3Parse;
        if (m3.m3_LoadModule(runtime, module) != null)
            return error.Wasm3Load;

        // Link host functions (for WASM-in-WASM plugin)
        _ = m3.m3_LinkRawFunction(module, "env", "log", "v(ii)", &hostLog);

        // Find exports
        return .{
            .env = env,
            .runtime = runtime,
            .module = module,
            .fn_init = try findFunction(module, "init"),
            .fn_frame = try findFunction(module, "frame"),
            .fn_get_cmd_ptr = try findFunction(module, "getCommandPtr"),
            .fn_get_cmd_len = try findFunction(module, "getCommandLen"),
        };
    }

    pub fn writeBytecode(self: *Wasm3, pngb: []const u8) void {
        const mem = m3.m3_GetMemory(self.runtime, null, null);
        @memcpy(mem[BYTECODE_OFFSET..][0..pngb.len], pngb);
        // Call setBytecodeLen
    }

    pub fn callInit(self: *Wasm3) !void {
        var result: m3.M3Result = null;
        result = m3.m3_Call(self.fn_init, 0, null);
        if (result != null) return error.Wasm3Call;
    }

    pub fn getCommandBuffer(self: *Wasm3) []const u8 {
        // Call getCommandPtr and getCommandLen, return slice
    }
};
```

## Conclusion

This system transforms runtime debugging from a slow, manual process into
instant, structured feedback. By validating the command buffer natively,
we catch most errors before they reach the browser. The JSON output is
designed specifically for LLM consumption, enabling faster iteration and
more precise fixes.

The implementation is straightforward because:
1. Command buffer format is already well-defined
2. MockGPU already validates similar invariants
3. wasm3 provides reliable WASM execution
4. Zig's C interop makes integration easy

**Recommended approach (wasm3-first):**
1. wasm3 integration + basic runner (2-3 days) - load WASM, call init/frame, get commands
2. Command parser + resource tracking (2 days) - parse all 53 commands, track IDs
3. Full validation + symptom diagnostics (2-3 days) - state machine, error detection
4. Phase output + multi-frame support (1-2 days) - init/frame inspection, frame comparison
5. Polish and document (1 day)

Total estimated effort: 8-11 days for full implementation.
MVP (wasm3 + parser + JSON dump) in 4-5 days provides immediate debugging value.
