# Embedded Executor with Plugin Architecture

> **Context References**:
> - Main project guide: `CLAUDE.md` (always read first)
> - Zig mastery guidelines: `/Users/hugo/Development/specs-llm/mastery/zig/`
> - Command buffer impl: `src/executor/command_buffer.zig`
> - WASM-in-WASM impl: `src/dsl/emitter/wasm.zig`
> - **Validator impl**: `src/cli/validate/cmd_validator.zig` (reference for hosts)
> - **wasm3 wrapper**: `src/cli/validate/wasm3.zig` (reference for native hosts)

---

## Overview

Bundle a plugin-selected WASM executor directly in the PNG payload, enabling fully
self-contained executables that run on any platform with a WASM interpreter.

**Goal**: A PNG file that contains everything needed to run - extract it, feed it
to wasm3/wasmi/native WebAssembly, and it outputs GPU commands.

**Key Principle**: The executor outputs a **command buffer** (existing format),
which any platform translates to native GPU calls. This preserves the current
architecture while enabling universal execution.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PNG FILE                                        │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ pNGb chunk (DEFLATE compressed together)                              │  │
│  │                                                                        │  │
│  │  ┌──────────────────────────────────────────────────────────────────┐ │  │
│  │  │ WASM Executor (plugin-selected)                                  │ │  │
│  │  │                                                                   │ │  │
│  │  │  Plugins included based on DSL analysis:                         │ │  │
│  │  │    [core]     Always: bytecode parse, command emit               │ │  │
│  │  │    [render]   If #renderPipeline, #renderPass used               │ │  │
│  │  │    [compute]  If #computePipeline, #computePass used             │ │  │
│  │  │    [wasm]     If #wasmCall, #data wasm={} used                   │ │  │
│  │  │    [anim]     If #animation, scene table used                    │ │  │
│  │  │    [texture]  If #texture with image/video used                  │ │  │
│  │  │                                                                   │ │  │
│  │  │  Input:  Bytecode + Data (from payload)                          │ │  │
│  │  │  Output: Command Buffer (platform-agnostic)                      │ │  │
│  │  └──────────────────────────────────────────────────────────────────┘ │  │
│  │                                                                        │  │
│  │  ┌──────────────────────────────────────────────────────────────────┐ │  │
│  │  │ Bytecode + Data Section                                          │ │  │
│  │  │  - Resource creation opcodes                                     │ │  │
│  │  │  - WGSL shader source                                            │ │  │
│  │  │  - Embedded .wasm modules (if [wasm] plugin)                     │ │  │
│  │  │  - Vertex data, textures                                         │ │  │
│  │  └──────────────────────────────────────────────────────────────────┘ │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        ▼                             ▼                             ▼
   ┌─────────┐                 ┌──────────┐                 ┌─────────────┐
   │ Browser │                 │   iOS    │                 │   Android   │
   │ WebGPU  │                 │  Metal   │                 │   Vulkan    │
   │         │                 │  wasm3   │                 │   wasm3     │
   └─────────┘                 └──────────┘                 └─────────────┘

   Each platform:
   1. Extracts WASM + data from PNG
   2. Runs WASM (native or interpreter)
   3. Reads command buffer output
   4. Executes on native GPU API
```

---

## Relation to Existing Work

### Command Buffer (KEEP - Already Implemented)

The command buffer in `src/executor/command_buffer.zig` is the foundation:

```zig
pub const Cmd = enum(u8) {
    // Resource Creation (0x01-0x0D)
    create_buffer = 0x01,
    create_texture = 0x02,
    // ...

    // Pass Operations (0x10-0x1A)
    begin_render_pass = 0x10,
    draw = 0x15,
    // ...

    // WASM Module Operations (0x30-0x31) ← KEEP as plugin
    init_wasm_module = 0x30,
    call_wasm_func = 0x31,

    // Control (0xF0, 0xFF)
    submit = 0xF0,
    end = 0xFF,
};
```

**This format is already platform-agnostic.** The embedded executor will output
this exact format, and platform hosts will consume it.

### WASM-in-WASM (KEEP - As Plugin)

The `#wasmCall` and `#data wasm={...}` features are **not removed** but become
an **optional plugin**:

```
// When DSL uses these features, the [wasm] plugin is included:

#wasmCall mvpMatrix {
  module={ url="physics.wasm" }   // Embedded in payload
  func=simulate
  returns="array<f32, 64>"
  args=[time.total canvas.width]
}

#data physicsState {
  wasm={
    module={ url="physics.wasm" }
    func=getState
    returns="array<f32, 1024>"
  }
}
```

**Use cases for [wasm] plugin**:
- Physics engines (Rapier, box2d compiled to WASM)
- Complex math libraries (matrix operations, FFT)
- Game logic that's too complex for WGSL
- Deterministic simulation (WASM is deterministic, GPU compute isn't)

### Multiplatform Plan (EXTEND)

The `docs/multiplatform-command-buffer-plan.md` vision is extended:

| Original Plan | This Plan |
|--------------|-----------|
| Port dispatcher from JS to Zig | Same |
| 21 portable opcodes | Same, but [wasm] plugin adds 0x30-0x31 |
| Native builds with Dawn/Mach | Same |
| Shared executor loaded separately | **Executor embedded in PNG** |

### Data Generation Plan (COMPLEMENT)

The compute-first approach in `docs/data-generation-plan.md` complements [wasm]:

| Approach | When to Use |
|----------|-------------|
| Compile-time generators | Small static meshes (<2KB) |
| Compute shaders | Large dynamic data, GPU-parallel |
| **[wasm] plugin** | Deterministic, complex CPU logic, existing WASM libs |

### LLM Runtime Validator (REUSE)

The `pngine validate` command (implemented in `src/cli/validate/`) provides
infrastructure that native hosts should reuse:

| Component | Location | Reuse For |
|-----------|----------|-----------|
| wasm3 wrapper | `validate/wasm3.zig` | Native host WASM execution |
| Command parser | `validate/cmd_validator.zig` | Reference implementation for hosts |
| Descriptor parsing | `parseTextureDescriptor()` etc | Reading resource descriptors |
| Error detection | E001-E008 codes | Debugging on any platform |
| Special IDs | `CANVAS_TEXTURE_ID`, `NO_DEPTH_TEXTURE_ID` | Shared constants |

**Critical Lesson Learned**: The `DescriptorType` enum must match exactly between
encoder and validator. During validator development, a mismatch (texture=0x02 vs
0x01) caused silent parsing failures. The embedded executor must use shared types.

---

## Robustness: Shared Types and Validation

### Shared Descriptor Types

To prevent encoder/decoder/validator/host mismatches, create a single source
of truth for descriptor layouts:

```zig
// src/executor/descriptors.zig (NEW - shared by all components)

/// Descriptor type tags - MUST match everywhere!
/// Used by: DescriptorEncoder, cmd_validator, native hosts
pub const DescriptorType = enum(u8) {
    texture = 0x01,
    sampler = 0x02,
    bind_group = 0x03,
    bind_group_layout = 0x04,
    render_pipeline = 0x05,
    compute_pipeline = 0x06,
    render_pass = 0x07,
    pipeline_layout = 0x08,
};

/// Texture descriptor fields
pub const TextureField = enum(u8) {
    width = 0x01,
    height = 0x02,
    depth = 0x03,
    format = 0x04,
    usage = 0x05,
    dimension = 0x06,
    mip_level_count = 0x07,
    sample_count = 0x08,
    view_formats = 0x09,
};

/// Special resource IDs
pub const CANVAS_TEXTURE_ID: u16 = 0xFFFE;  // Browser-managed canvas texture
pub const NO_DEPTH_TEXTURE_ID: u16 = 0xFFFF; // No depth attachment

// Parsing functions shared across implementations
pub fn parseTextureDescriptor(data: []const u8) ?TextureInfo { ... }
pub fn parseSamplerDescriptor(data: []const u8) ?SamplerInfo { ... }
```

**Files to update:**
- `src/bytecode/DescriptorEncoder.zig` - Import from `descriptors.zig`
- `src/cli/validate/cmd_validator.zig` - Import from `descriptors.zig`
- Native hosts - Import or replicate these constants

### WASM Memory Layout Contract

The validator established this pattern for accessing WASM memory:

```zig
// Pattern used in validate/executor.zig - copy to native hosts
if (runtime.getMemory()) |mem| {
    // Full WASM linear memory available for:
    // - Descriptor parsing (reading at desc_ptr offsets)
    // - Bounds validation (checking ptr + len <= mem.len)
    // - Command buffer reading (after frame() call)
    validator.setWasmMemory(mem);
}
```

**Memory Regions** (documented for native host implementers):

```
WASM Linear Memory Layout:
┌────────────────────────────────────────┐ 0x0000
│ Stack (grows down)                     │
├────────────────────────────────────────┤ ~0x10000
│ Bytecode Buffer (getBytecodePtr())     │
│   - Copied from payload.bytecode       │
│   - Size: setBytecodeLen()             │
├────────────────────────────────────────┤
│ Data Buffer (getDataPtr())             │
│   - Copied from payload.data           │
│   - Size: setDataLen()                 │
│   - Contains: WGSL, vertex data, etc.  │
├────────────────────────────────────────┤
│ Command Buffer (getCommandPtr())       │
│   - Written by init() and frame()      │
│   - Size: getCommandLen()              │
│   - Contains: GPU commands             │
├────────────────────────────────────────┤
│ Descriptors (written during init)      │
│   - Referenced by desc_ptr in commands │
│   - Parsed using DescriptorType tags   │
└────────────────────────────────────────┘ mem.len
```

### Validation Mode for Native Hosts

Native hosts (iOS, Android, Desktop) should optionally validate command buffers
before GPU execution, using the same error codes as the CLI validator:

```swift
// PNGineViewer/Engine.swift (iOS example)

class PNGineEngine {
    var validateCommands: Bool = false  // Enable for debugging

    func frame(time: Float, size: CGSize) {
        wasm.call("frame", time, size.width, size.height)
        let commands = getCommandBuffer()

        if validateCommands {
            let errors = validateCommandBuffer(commands, wasmMemory)
            for error in errors {
                print("[PNGine] \(error.code): \(error.message) at cmd \(error.commandIndex)")
            }
        }

        executeFrameCommands(commands)
    }
}
```

**Error Codes** (from `cmd_validator.zig`, use in all hosts):

| Code | Description | Host Action |
|------|-------------|-------------|
| E001 | Invalid resource reference | Skip command, log error |
| E002 | Buffer too small | Skip write, log error |
| E003 | Missing required resource | Fatal error |
| E004 | Out-of-bounds memory access | Fatal error |
| E005 | Invalid usage flags | Warning only |
| E006 | Invalid texture properties | Skip texture creation |
| E007 | Invalid command sequence | Fatal error |
| E008 | Unrecognized command | Skip command |

### Plugin Command Validation

Validate that plugin-specific commands match the payload's plugin flags:

```zig
// During command parsing
switch (cmd) {
    0x30, 0x31 => { // INIT_WASM_MODULE, CALL_WASM_FUNC
        if (!plugins.wasm) {
            return error.PluginNotEnabled; // E009
        }
    },
    0x38, 0x39 => { // LOAD_IMAGE, BIND_VIDEO_FRAME
        if (!plugins.texture) {
            return error.PluginNotEnabled;
        }
    },
    // ...
}
```

---

## Plugin Architecture

### Plugin Definitions

```zig
// src/executor/plugins.zig

pub const Plugin = enum {
    core,      // Always included
    render,    // Render pipelines, passes, draw
    compute,   // Compute pipelines, dispatch
    wasm,      // Nested WASM execution
    animation, // Scene table, timeline
    texture,   // Image/video textures
};

pub const PluginSet = packed struct {
    core: bool = true,       // Always true
    render: bool = false,
    compute: bool = false,
    wasm: bool = false,
    animation: bool = false,
    texture: bool = false,

    pub fn toU8(self: PluginSet) u8 {
        return @bitCast(self);
    }

    pub fn fromU8(byte: u8) PluginSet {
        return @bitCast(byte);
    }
};
```

### DSL Feature Detection

The compiler analyzes the AST to determine required plugins:

```zig
// src/dsl/Analyzer.zig (extension)

pub fn detectPlugins(self: *Analyzer) PluginSet {
    var plugins = PluginSet{};

    for (self.ast.nodes.items(.tag)) |tag| {
        switch (tag) {
            .macro_render_pipeline, .macro_render_pass => plugins.render = true,
            .macro_compute_pipeline, .macro_compute_pass => plugins.compute = true,
            .macro_wasm_call => plugins.wasm = true,
            .macro_animation => plugins.animation = true,
            .macro_texture => {
                // Check if texture has image/video property
                if (self.hasImageOrVideo(node)) plugins.texture = true;
            },
            else => {},
        }
    }

    // Check #data for wasm={...} property
    for (self.symbols.data.values()) |info| {
        if (self.hasWasmProperty(info.node)) plugins.wasm = true;
    }

    return plugins;
}
```

### Conditional Compilation

```zig
// src/executor/dispatcher.zig

const plugins = @import("plugins");

pub fn dispatch(self: *Dispatcher, cmd: Opcode) !void {
    switch (cmd) {
        // Core (always available)
        .create_buffer => self.handleCreateBuffer(),
        .write_buffer => self.handleWriteBuffer(),
        .submit => self.handleSubmit(),
        .end => return,

        // Render plugin
        .create_render_pipeline => if (plugins.render) self.handleCreateRenderPipeline() else unreachable,
        .begin_render_pass => if (plugins.render) self.handleBeginRenderPass() else unreachable,
        .draw => if (plugins.render) self.handleDraw() else unreachable,

        // Compute plugin
        .create_compute_pipeline => if (plugins.compute) self.handleCreateComputePipeline() else unreachable,
        .dispatch => if (plugins.compute) self.handleDispatch() else unreachable,

        // WASM plugin
        .init_wasm_module => if (plugins.wasm) self.handleInitWasmModule() else unreachable,
        .call_wasm_func => if (plugins.wasm) self.handleCallWasmFunc() else unreachable,

        // Animation plugin
        .set_scene => if (plugins.animation) self.handleSetScene() else unreachable,

        // etc.
    }
}
```

---

## WASM-in-WASM Plugin Details

### Current Implementation Status

| Component | Status | Location |
|-----------|--------|----------|
| DSL `#wasmCall` | ✅ Implemented | `src/dsl/emitter/wasm.zig` |
| DSL `#data wasm={}` | ✅ Syntax parsed | `src/dsl/emitter/resources.zig` |
| Opcodes 0x30-0x31 | ✅ Defined | `src/bytecode/opcodes.zig` |
| Dispatcher handlers | ✅ Implemented | `src/executor/dispatcher.zig` |
| Command buffer emission | ✅ Implemented | `src/executor/command_buffer.zig` |
| JS runtime | ⚠️ Stubs only | `npm/pngine/src/gpu.js` |

### What Needs to Complete [wasm] Plugin

1. **JS Implementation** (for browser):
```javascript
// npm/pngine/src/gpu.js

async _initWasmModule(moduleId, dataPtr, dataLen) {
  const wasmBytes = new Uint8Array(this.memory.buffer, dataPtr, dataLen);
  const module = await WebAssembly.compile(wasmBytes);
  const instance = await WebAssembly.instantiate(module, {
    env: {
      // Minimal imports for embedded WASM
      memory: this.nestedMemory,
    }
  });
  this.wasmModules.set(moduleId, instance);
}

_callWasmFunc(callId, moduleId, namePtr, nameLen, argsPtr, argsLen) {
  const instance = this.wasmModules.get(moduleId);
  const funcName = this._readString(namePtr, nameLen);
  const args = this._decodeWasmArgs(argsPtr, argsLen);

  const result = instance.exports[funcName](...args);
  this.wasmResults.set(callId, result);
}
```

2. **Native Implementation** (for iOS/Android):
```zig
// src/executor/backends/wasm3.zig

const wasm3 = @cImport(@cInclude("wasm3.h"));

pub fn initWasmModule(self: *Self, module_id: u16, wasm_bytes: []const u8) !void {
    const env = wasm3.m3_NewEnvironment();
    const runtime = wasm3.m3_NewRuntime(env, 64 * 1024, null);

    var module: wasm3.IM3Module = undefined;
    _ = wasm3.m3_ParseModule(env, &module, wasm_bytes.ptr, wasm_bytes.len);
    _ = wasm3.m3_LoadModule(runtime, module);

    self.wasm_modules.put(module_id, .{ .runtime = runtime, .module = module });
}

pub fn callWasmFunc(self: *Self, module_id: u16, func_name: []const u8, args: []const u8) ![]u8 {
    const entry = self.wasm_modules.get(module_id) orelse return error.ModuleNotFound;

    var func: wasm3.IM3Function = undefined;
    _ = wasm3.m3_FindFunction(&func, entry.runtime, func_name.ptr);

    // Call and return result
    _ = wasm3.m3_Call(func, @intCast(args.len / 4), @ptrCast(args.ptr));
    // ...
}
```

### [wasm] Plugin Size Impact

| Component | Without [wasm] | With [wasm] |
|-----------|---------------|-------------|
| Dispatcher code | ~6KB | +2KB |
| wasm3 library | 0 | +80KB (native only) |
| Payload | N/A | +embedded .wasm size |

**Browser**: No extra size (uses native WebAssembly)
**Native**: +80KB for wasm3 interpreter

---

## Payload Format (v5)

```
pNGb Payload Header (36 bytes):
┌─────────────────────────────────────────────────────────────────┐
│ magic: [4]u8 = "PNGB"                                            │
│ version: u16 = 5                                                 │
│ flags: u16                                                       │
│   bit 0: has_embedded_executor                                  │
│   bit 1: has_animation_table                                    │
│   bit 2-7: reserved                                             │
│ plugins: u8 (PluginSet bitfield)                                │
│ reserved: u8                                                     │
│ executor_offset: u32 (0 if not embedded)                        │
│ executor_length: u32                                            │
│ bytecode_offset: u32                                            │
│ bytecode_length: u32                                            │
│ data_offset: u32                                                │
│ data_length: u32                                                │
│ string_table_offset: u32                                        │
│ string_table_length: u32                                        │
├─────────────────────────────────────────────────────────────────┤
│ WASM Executor (if embedded)                                      │
│   Plugin-selected, ReleaseSmall optimized                       │
│   Raw size: 5-20KB depending on plugins                         │
├─────────────────────────────────────────────────────────────────┤
│ Bytecode                                                         │
│   Resource creation, frame definitions                          │
├─────────────────────────────────────────────────────────────────┤
│ String Table                                                     │
│   Entry points, function names                                  │
├─────────────────────────────────────────────────────────────────┤
│ Data Section                                                     │
│   WGSL shader code                                              │
│   Embedded .wasm modules (for [wasm] plugin)                    │
│   Vertex data, textures                                         │
└─────────────────────────────────────────────────────────────────┘
         ↓ Entire pNGb chunk DEFLATE compressed
```

---

## WASM Executor Interface

### Exports (called by host)

```zig
// src/wasm_entry.zig

/// Initialize with bytecode and data. Call once.
export fn init() void {
    executor.parseHeader();
    executor.emitResourceCreation();
}

/// Render a frame. Call per-frame.
export fn frame(time: f32, width: u32, height: u32) void {
    executor.updateUniforms(time, width, height);
    executor.emitFrameCommands();
}

/// Get pointer to command buffer output.
export fn getCommandPtr() [*]const u8 {
    return executor.command_buffer.ptr();
}

/// Get length of command buffer.
export fn getCommandLen() u32 {
    return executor.command_buffer.len();
}

/// Where host should write bytecode.
export fn getBytecodePtr() [*]u8 {
    return &bytecode_buffer;
}

/// Tell executor bytecode length.
export fn setBytecodeLen(len: u32) void {
    executor.bytecode_len = len;
}

/// Where host should write data section.
export fn getDataPtr() [*]u8 {
    return &data_buffer;
}

/// Tell executor data section length.
export fn setDataLen(len: u32) void {
    executor.data_len = len;
}
```

### Imports (provided by host)

```zig
// Minimal imports - only what's needed

extern "env" fn log(ptr: [*]const u8, len: u32) void;  // Debug logging (optional)

// For [wasm] plugin only - nested WASM needs host help
extern "env" fn wasmInstantiate(module_id: u16, wasm_ptr: [*]const u8, wasm_len: u32) void;
extern "env" fn wasmCall(call_id: u16, module_id: u16, func_ptr: [*]const u8, func_len: u32, args_ptr: [*]const u8, args_len: u32) void;
extern "env" fn wasmGetResult(call_id: u16, out_ptr: [*]u8, out_len: u32) u32;
```

**Note**: The [wasm] plugin requires host cooperation because WASM cannot instantiate
other WASM modules directly. The host (JS or wasm3) handles the actual instantiation.

---

## Build System

### Pre-built Executor Variants

```zig
// build.zig

const plugin_variants = [_]PluginSet{
    // Common combinations - pre-built for fast compilation
    .{ .render = true },                                    // render-only
    .{ .compute = true },                                   // compute-only
    .{ .render = true, .compute = true },                   // render+compute
    .{ .render = true, .animation = true },                 // animated render
    .{ .render = true, .compute = true, .animation = true }, // full (no wasm)
    .{ .render = true, .wasm = true },                      // render+wasm
    .{ .render = true, .compute = true, .wasm = true },     // all features
};

pub fn buildExecutorVariants(b: *std.Build) void {
    for (plugin_variants) |plugins| {
        const name = pluginSetName(plugins);

        const exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path("src/wasm_entry.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = .ReleaseSmall,
        });

        // Set plugin flags
        const options = b.addOptions();
        options.addOption(bool, "render", plugins.render);
        options.addOption(bool, "compute", plugins.compute);
        options.addOption(bool, "wasm", plugins.wasm);
        options.addOption(bool, "animation", plugins.animation);
        options.addOption(bool, "texture", plugins.texture);
        exe.root_module.addOptions("plugins", options);

        // Size optimizations
        exe.root_module.strip = true;
        exe.root_module.unwind_tables = false;

        b.installArtifact(exe);
    }
}
```

### Compiler Embedding

```zig
// src/dsl/Emitter.zig (extension)

pub fn embedExecutor(self: *Emitter, plugins: PluginSet) !void {
    // Find pre-built WASM for this plugin set
    const wasm_path = try self.findExecutorWasm(plugins);
    const wasm_bytes = try std.fs.cwd().readFileAlloc(self.gpa, wasm_path, 1024 * 1024);
    defer self.gpa.free(wasm_bytes);

    // Add to payload
    self.executor_data = wasm_bytes;
    self.header.flags |= FLAG_HAS_EMBEDDED_EXECUTOR;
    self.header.plugins = plugins.toU8();
}

fn findExecutorWasm(self: *Emitter, plugins: PluginSet) ![]const u8 {
    // Look in embedded resources or build cache
    const name = pluginSetName(plugins);
    return std.fmt.allocPrint(self.gpa, "executors/{s}.wasm", .{name});
}
```

---

## Host Implementations

### Browser (JavaScript)

```javascript
// npm/pngine/src/loader.js (~150 lines)

export async function loadPNG(pngUrl, canvas) {
  // 1. Fetch and extract payload
  const png = await fetch(pngUrl).then(r => r.arrayBuffer());
  const payload = extractPNGb(png);

  // 2. Get executor (embedded or shared)
  let wasmBytes;
  if (payload.hasEmbeddedExecutor) {
    wasmBytes = payload.executor;
  } else {
    // Fallback to shared executor based on plugins
    const variant = pluginSetName(payload.plugins);
    wasmBytes = await fetch(`/pngine-${variant}.wasm`).then(r => r.arrayBuffer());
  }

  // 3. Setup WebGPU
  const adapter = await navigator.gpu.requestAdapter();
  const device = await adapter.requestDevice();
  const context = canvas.getContext('webgpu');
  context.configure({ device, format: navigator.gpu.getPreferredCanvasFormat() });

  // 4. Instantiate WASM
  const memory = new WebAssembly.Memory({ initial: 32 }); // 2MB
  const imports = {
    env: {
      memory,
      log: (ptr, len) => console.log(readString(memory, ptr, len)),
      // [wasm] plugin imports
      wasmInstantiate: (id, ptr, len) => instantiateNested(id, ptr, len),
      wasmCall: (callId, modId, namePtr, nameLen, argsPtr, argsLen) => callNested(...),
      wasmGetResult: (callId, outPtr, outLen) => copyNestedResult(...),
    }
  };

  const wasm = await WebAssembly.instantiate(wasmBytes, imports);

  // 5. Copy data to WASM memory
  const bytecodePtr = wasm.exports.getBytecodePtr();
  new Uint8Array(memory.buffer, bytecodePtr).set(payload.bytecode);
  wasm.exports.setBytecodeLen(payload.bytecode.length);

  const dataPtr = wasm.exports.getDataPtr();
  new Uint8Array(memory.buffer, dataPtr).set(payload.data);
  wasm.exports.setDataLen(payload.data.length);

  // 6. Initialize (creates resources)
  wasm.exports.init();
  const initCommands = readCommandBuffer(memory, wasm.exports);
  const resources = executeCommands(device, initCommands, payload.data);

  // 7. Return frame function
  return {
    frame(time) {
      wasm.exports.frame(time, canvas.width, canvas.height);
      const commands = readCommandBuffer(memory, wasm.exports);
      executeFrameCommands(device, context, resources, commands);
    }
  };
}

// Command executor (~200 lines) - reads command buffer, calls WebGPU
function executeCommands(device, commands, data) {
  const resources = new Map();
  const view = new DataView(commands.buffer, commands.byteOffset);
  let offset = 8; // Skip header

  while (offset < commands.byteLength) {
    const cmd = view.getUint8(offset++);
    switch (cmd) {
      case 0x01: // create_buffer
        const id = view.getUint16(offset, true); offset += 2;
        const size = view.getUint32(offset, true); offset += 4;
        const usage = view.getUint8(offset++);
        resources.set(id, device.createBuffer({ size, usage: translateUsage(usage) }));
        break;
      // ... other commands
    }
  }
  return resources;
}
```

### iOS (Swift + wasm3)

```swift
// PNGineViewer/Engine.swift

import wasm3

class PNGineEngine {
    private var runtime: UnsafeMutablePointer<M3Runtime>?
    private var resources: [UInt16: MTLResource] = [:]
    private let device: MTLDevice

    init(pngData: Data, device: MTLDevice) throws {
        self.device = device

        // Extract payload
        let payload = try extractPNGb(from: pngData)

        // Initialize wasm3
        let env = m3_NewEnvironment()
        runtime = m3_NewRuntime(env, 2 * 1024 * 1024, nil) // 2MB stack

        // Load executor WASM
        var module: IM3Module?
        payload.executor.withUnsafeBytes { ptr in
            m3_ParseModule(env, &module, ptr.baseAddress, UInt32(ptr.count))
        }
        m3_LoadModule(runtime, module)

        // Link imports
        linkImports()

        // Copy data to WASM memory
        copyDataToWasm(payload)

        // Initialize
        callWasmExport("init")
        executeInitCommands()
    }

    func frame(time: Float, size: CGSize) {
        // Call frame export
        var timeVal = time
        var width = UInt32(size.width)
        var height = UInt32(size.height)

        if let frameFunc = findFunction("frame") {
            m3_Call(frameFunc, 3, &timeVal, &width, &height)
        }

        executeFrameCommands()
    }

    private func executeInitCommands() {
        let commands = getCommandBuffer()
        var offset = 8 // Skip header

        while offset < commands.count {
            let cmd = commands[offset]
            offset += 1

            switch cmd {
            case 0x01: // create_buffer
                let id = commands.readU16(at: &offset)
                let size = commands.readU32(at: &offset)
                let usage = commands[offset]; offset += 1

                let buffer = device.makeBuffer(length: Int(size), options: translateUsage(usage))
                resources[id] = buffer

            // ... other commands translated to Metal
            }
        }
    }
}
```

### Android (Kotlin + wasm3)

```kotlin
// PNGineViewer/Engine.kt

class PNGineEngine(pngData: ByteArray, private val device: VkDevice) {
    private val runtime: Wasm3Runtime
    private val resources = mutableMapOf<Int, VulkanResource>()

    init {
        val payload = extractPNGb(pngData)

        runtime = Wasm3Runtime(stackSize = 2 * 1024 * 1024)
        runtime.loadModule(payload.executor)
        runtime.linkImports(createImports())

        copyDataToWasm(payload)

        runtime.call("init")
        executeInitCommands()
    }

    fun frame(time: Float, width: Int, height: Int) {
        runtime.call("frame", time, width, height)
        executeFrameCommands()
    }

    private fun executeInitCommands() {
        val commands = getCommandBuffer()
        // ... similar to iOS, but with Vulkan calls
    }
}
```

---

## Size Estimates

### Executor WASM Sizes (ReleaseSmall, stripped)

| Plugin Set | Raw | Compressed |
|------------|-----|------------|
| [core] | 4KB | ~1.5KB |
| [core, render] | 7KB | ~2.5KB |
| [core, compute] | 6KB | ~2.2KB |
| [core, render, compute] | 9KB | ~3.2KB |
| [core, render, animation] | 10KB | ~3.5KB |
| [core, render, compute, wasm] | 12KB | ~4KB |
| [full - all plugins] | 15KB | ~5KB |

### Total PNG Sizes (Typical)

| Content | Executor | Bytecode | WGSL | Data | Total Compressed |
|---------|----------|----------|------|------|------------------|
| Simple triangle | 2.5KB | 0.3KB | 0.2KB | 0.1KB | **~3KB** |
| Rotating cube | 2.5KB | 0.5KB | 0.5KB | 0.4KB | **~4KB** |
| Boids simulation | 3.5KB | 0.8KB | 1.0KB | 0.2KB | **~5KB** |
| Physics demo [wasm] | 4KB | 0.6KB | 0.5KB | 50KB | **~25KB** |

---

## Implementation Phases

### Phase 0: Shared Types Refactor (Prerequisite)

**Rationale**: The validator work revealed that encoder/decoder type mismatches
cause silent failures. Create shared types BEFORE any new development.

**Files to create:**
- `src/executor/descriptors.zig` - **NEW** Shared descriptor types and parsing

**Files to update:**
- `src/bytecode/DescriptorEncoder.zig` - Import from `descriptors.zig`
- `src/cli/validate/cmd_validator.zig` - Import from `descriptors.zig`

**Deliverable**: Single source of truth for DescriptorType, field enums, special IDs.
All existing tests pass.

### Phase 1: Payload Format Extension

**Files to modify:**
- `src/bytecode/format.zig` - Add v5 header fields
- `src/png/embed.zig` - Handle larger payloads
- `src/png/extract.zig` - Extract executor section

**Deliverable**: PNG can contain executor section, roundtrip works.

### Phase 2: Plugin Infrastructure

**Files to modify:**
- `src/executor/plugins.zig` - **NEW** Plugin definitions
- `src/dsl/Analyzer.zig` - Feature detection
- `build.zig` - Multi-variant build

**Deliverable**: Compiler detects plugins, builds correct variant.

### Phase 3: Executor Refactor

**Files to modify:**
- `src/wasm_entry.zig` - New entry point with clean exports
- `src/executor/dispatcher.zig` - Conditional compilation
- `src/executor/command_buffer.zig` - Ensure output-only mode works

**Deliverable**: WASM executor with plugin selection compiles.

### Phase 4: Embedding Integration

**Files to modify:**
- `src/dsl/Emitter.zig` - Embed executor in payload
- `src/cli.zig` - `--embed-executor` flag

**Deliverable**: `pngine shader.pngine -o out.png --embed-executor` works.

### Phase 5: Complete [wasm] Plugin

**Files to modify:**
- `npm/pngine/src/gpu.js` - Implement nested WASM execution
- `src/executor/backends/wasm3.zig` - **NEW** Native nested WASM

**Deliverable**: `#wasmCall` and `#data wasm={}` fully functional.

### Phase 6: Browser Loader Refactor

**Files to modify:**
- `npm/pngine/src/loader.js` - **NEW** Minimal loader
- `npm/pngine/src/commands.js` - **NEW** Command executor

**Deliverable**: Browser can run embedded executor PNGs.

### Phase 7: Native Viewers

**New files:**
- `viewers/ios/` - Swift + wasm3 + Metal
- `viewers/android/` - Kotlin + wasm3 + Vulkan
- `viewers/native/` - Zig + wasm3 + Dawn

**Reference implementation:**
- Copy wasm3 integration pattern from `src/cli/validate/wasm3.zig`
- Use command parsing logic from `src/cli/validate/cmd_validator.zig`
- Import shared types from `src/executor/descriptors.zig`
- Enable `--validate` flag for debugging (uses E001-E008 error codes)

**Deliverable**: PNGs run on iOS, Android, Desktop with optional validation mode.

---

## Command Set (Final)

### Portable Commands (All Platforms)

```
Resource Creation (0x01-0x07):
  0x01 CREATE_BUFFER      [id:u16] [size:u32] [usage:u8]
  0x02 CREATE_TEXTURE     [id:u16] [desc_ptr:u32] [desc_len:u32]
  0x03 CREATE_SAMPLER     [id:u16] [desc_ptr:u32] [desc_len:u32]
  0x04 CREATE_SHADER      [id:u16] [code_ptr:u32] [code_len:u32]
  0x05 CREATE_RENDER_PIPE [id:u16] [desc_ptr:u32] [desc_len:u32]
  0x06 CREATE_COMPUTE_PIPE[id:u16] [desc_ptr:u32] [desc_len:u32]
  0x07 CREATE_BIND_GROUP  [id:u16] [layout:u16] [entries_ptr:u32] [len:u32]

Pass Operations (0x10-0x19):
  0x10 BEGIN_RENDER_PASS  [color:u16] [load:u8] [store:u8] [depth:u16]
  0x11 BEGIN_COMPUTE_PASS (no args)
  0x12 SET_PIPELINE       [id:u16]
  0x13 SET_BIND_GROUP     [slot:u8] [id:u16]
  0x14 SET_VERTEX_BUFFER  [slot:u8] [id:u16]
  0x15 DRAW               [vtx:u32] [inst:u32] [first_vtx:u32] [first_inst:u32]
  0x16 DRAW_INDEXED       [idx:u32] [inst:u32] [first:u32] [base:i32] [first_inst:u32]
  0x17 END_PASS           (no args)
  0x18 DISPATCH           [x:u32] [y:u32] [z:u32]
  0x19 SET_INDEX_BUFFER   [id:u16] [format:u8]

Queue Operations (0x20-0x22):
  0x20 WRITE_BUFFER       [id:u16] [offset:u32] [data_ptr:u32] [data_len:u32]
  0x21 COPY_BUFFER        [src:u16] [src_off:u32] [dst:u16] [dst_off:u32] [size:u32]
  0x22 COPY_TEXTURE       [src:u16] [dst:u16] [w:u16] [h:u16]

Control (0xF0, 0xFF):
  0xF0 SUBMIT             (no args)
  0xFF END                (no args)
```

### Plugin-Specific Commands

```
[wasm] Plugin (0x30-0x32):
  0x30 INIT_WASM_MODULE   [module_id:u16] [data_ptr:u32] [data_len:u32]
  0x31 CALL_WASM_FUNC     [call_id:u16] [module_id:u16] [name_ptr:u32] [name_len:u32] [args_ptr:u32] [args_len:u32]
  0x32 WRITE_FROM_WASM    [call_id:u16] [buffer_id:u16] [offset:u32] [len:u32]

[texture] Plugin (0x38-0x39):
  0x38 LOAD_IMAGE         [id:u16] [data_ptr:u32] [data_len:u32]
  0x39 BIND_VIDEO_FRAME   [video_id:u16] [tex_id:u16]

[animation] Plugin (0x3A):
  0x3A SET_SCENE          [scene_id:u16] [transition:u8]
```

---

## Success Criteria

1. **Self-contained PNGs**: `pngine shader.pngine -o out.png --embed-executor` produces
   runnable PNG
2. **Plugin selection**: Only needed code included, size varies by features
3. **[wasm] plugin works**: `#wasmCall` executes embedded WASM modules
4. **Browser runs embedded**: Minimal JS loader (~300 lines) executes PNGs
5. **Native viewers work**: iOS/Android apps run PNGs via wasm3
6. **Backward compatible**: Non-embedded PNGs still work with shared executor
7. **Size targets met**: Simple shaders ~3-4KB, complex ~10-20KB
8. **Shared types**: All components use `src/executor/descriptors.zig` - no enum mismatches
9. **Validation mode**: Native hosts can validate command buffers with E001-E008 codes
10. **Cross-platform errors**: Same error codes reported on browser, iOS, Android, Desktop

---

## Related Documents

- `docs/llm-runtime-testing-plan.md` - **COMPLETE** - Validator implementation (reuse for hosts)
- `docs/multiplatform-command-buffer-plan.md` - Platform abstraction vision
- `docs/command-buffer-refactor-plan.md` - JS bundle optimization
- `docs/data-generation-plan.md` - Compute shader data generation
- `docs/remove-wasm-in-wasm-plan.md` - **SUPERSEDED** by this plan (keep as plugin)
- `src/executor/command_buffer.zig` - Existing command buffer implementation
- `src/cli/validate/cmd_validator.zig` - Reference command parsing for hosts
- `src/cli/validate/wasm3.zig` - Reference wasm3 integration for native hosts
