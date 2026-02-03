# Zig Mastery Compliance Plan

## Overview

This plan addresses violations of the Zig Mastery guidelines found in the native
GPU backend and related files. The goal is to bring all code into compliance
with the established patterns for safety, maintainability, and correctness.

**Files Affected:**
- `src/executor/wgpu_native_gpu.zig` (1750 lines) - Critical, needs major refactoring
- `src/native_api.zig` (616 lines) - Moderate issues
- `src/gpu/wgpu_c.zig` (545 lines) - Minor issues
- `src/dsl/emitter/init.zig` (323 lines) - Minor issues

**Mastery Principles Being Enforced:**
1. No recursion - use explicit stacks
2. Bounded loops with `for (0..MAX_X) |_|` with `else` fallback
3. 2+ assertions per function - pre-conditions and post-conditions
4. Explicitly-sized types (u32, i64, not usize except for slice indexing)
5. Static allocation - no malloc after init in runtime
6. Functions ≤ 70 lines (exception: state machines with labeled switch)

---

## Phase 1: Split wgpu_native_gpu.zig (Critical)

**Priority:** High
**Risk:** Medium (refactoring, but no logic changes)
**Estimated Complexity:** High

### Problem

The file is 1750 lines - far too large for maintainability. It contains multiple
distinct responsibilities mixed together:

1. Context management (instance, adapter, device, queue)
2. Resource creation (buffers, textures, shaders, pipelines, bind groups)
3. Pass operations (render pass, compute pass)
4. Command encoding (draw, dispatch, copy operations)
5. JSON descriptor parsing
6. Debug/diagnostic infrastructure

### Solution: Split into 6 Focused Modules

```
src/executor/
├── wgpu_native_gpu.zig      # Main entry point, Context struct (~200 lines)
├── wgpu_native/
│   ├── resources.zig        # Buffer, texture, shader, sampler creation (~300 lines)
│   ├── pipelines.zig        # Render/compute pipeline creation (~250 lines)
│   ├── bind_groups.zig      # Bind group and layout creation (~200 lines)
│   ├── passes.zig           # Render/compute pass operations (~300 lines)
│   ├── commands.zig         # Draw, dispatch, copy operations (~200 lines)
│   └── descriptors.zig      # JSON parsing for pipeline descriptors (~250 lines)
```

### Implementation Steps

#### Step 1.1: Create Module Structure

```zig
// src/executor/wgpu_native/resources.zig
//! Resource Creation for wgpu-native Backend
//!
//! Handles creation and management of GPU resources:
//! - Buffers (vertex, index, uniform, storage)
//! - Textures (2D, with mip levels)
//! - Shaders (WGSL compilation)
//! - Samplers (filtering, addressing)
//!
//! ## Design
//! - All resources stored in static arrays with bounded capacity
//! - Resource IDs are indices into these arrays
//! - No dynamic allocation after initialization
//!
//! ## Invariants
//! - Resource count never exceeds MAX_* constants
//! - All handles are valid or null (never dangling)

const std = @import("std");
const c = @import("../gpu/wgpu_c.zig");

pub const MAX_BUFFERS = 256;
pub const MAX_TEXTURES = 64;
pub const MAX_SHADERS = 64;
pub const MAX_SAMPLERS = 32;

pub const BufferEntry = struct {
    handle: c.Buffer,
    size: u32,
    usage: u32,
    mapped: bool,
};

pub const Resources = struct {
    buffers: [MAX_BUFFERS]BufferEntry = [_]BufferEntry{.{}} ** MAX_BUFFERS,
    buffer_count: u32 = 0,

    textures: [MAX_TEXTURES]TextureEntry = [_]TextureEntry{.{}} ** MAX_TEXTURES,
    texture_count: u32 = 0,

    // ... etc

    /// Create a GPU buffer with the specified size and usage flags.
    ///
    /// Pre-conditions:
    /// - device must be valid
    /// - size must be > 0 and aligned to 4 bytes
    /// - buffer_count < MAX_BUFFERS
    ///
    /// Post-conditions:
    /// - Returns valid buffer ID < MAX_BUFFERS
    /// - buffers[id].handle is valid
    /// - buffer_count is incremented
    pub fn createBuffer(
        self: *Resources,
        device: c.Device,
        size: u32,
        usage: u32,
        label: ?[*:0]const u8,
    ) !u32 {
        // Pre-conditions
        std.debug.assert(device != null);
        std.debug.assert(size > 0);
        std.debug.assert(size % 4 == 0); // WebGPU alignment requirement
        std.debug.assert(self.buffer_count < MAX_BUFFERS);

        const id = self.buffer_count;

        const desc = c.WGPUBufferDescriptor{
            .size = size,
            .usage = usage,
            .label = label,
            .mappedAtCreation = @intFromBool(false),
        };

        const handle = c.wgpuDeviceCreateBuffer(device, &desc);
        if (handle == null) {
            return error.BufferCreationFailed;
        }

        self.buffers[id] = .{
            .handle = handle,
            .size = size,
            .usage = usage,
            .mapped = false,
        };
        self.buffer_count += 1;

        // Post-conditions
        std.debug.assert(self.buffers[id].handle != null);
        std.debug.assert(self.buffer_count <= MAX_BUFFERS);

        return id;
    }
};
```

#### Step 1.2: Extract Pipeline Creation

```zig
// src/executor/wgpu_native/pipelines.zig
//! GPU Pipeline Creation
//!
//! Handles creation of render and compute pipelines from descriptors.
//! Supports both programmatic construction and JSON-based descriptors.
//!
//! ## Design
//! - Pipelines are immutable after creation
//! - Descriptors parsed with bounded iteration (MAX_JSON_TOKENS)
//! - Layout inference via "auto" keyword
//!
//! ## Invariants
//! - Pipeline count never exceeds MAX_*_PIPELINES
//! - All shader modules referenced must exist

const std = @import("std");
const c = @import("../gpu/wgpu_c.zig");
const descriptors = @import("descriptors.zig");

pub const MAX_RENDER_PIPELINES = 64;
pub const MAX_COMPUTE_PIPELINES = 64;
pub const MAX_VERTEX_ATTRIBUTES = 16;
pub const MAX_VERTEX_BUFFERS = 8;
pub const MAX_COLOR_TARGETS = 4;

pub const RenderPipelineEntry = struct {
    handle: c.RenderPipeline,
    layout: c.PipelineLayout,
    vertex_buffer_count: u32,
};

pub const Pipelines = struct {
    render_pipelines: [MAX_RENDER_PIPELINES]RenderPipelineEntry = undefined,
    render_pipeline_count: u32 = 0,

    compute_pipelines: [MAX_COMPUTE_PIPELINES]ComputePipelineEntry = undefined,
    compute_pipeline_count: u32 = 0,

    /// Create a render pipeline from a JSON descriptor.
    ///
    /// Pre-conditions:
    /// - device must be valid
    /// - descriptor must be valid JSON
    /// - render_pipeline_count < MAX_RENDER_PIPELINES
    ///
    /// Post-conditions:
    /// - Returns valid pipeline ID
    /// - render_pipelines[id].handle is valid
    pub fn createRenderPipelineFromDescriptor(
        self: *Pipelines,
        device: c.Device,
        desc_json: []const u8,
        shaders: *const ShaderTable,
        surface_format: c.WGPUTextureFormat,
    ) !u32 {
        // Pre-conditions
        std.debug.assert(device != null);
        std.debug.assert(desc_json.len > 0);
        std.debug.assert(self.render_pipeline_count < MAX_RENDER_PIPELINES);

        // Parse with bounded iteration
        var parsed = try descriptors.parseRenderPipelineDescriptor(desc_json);

        // ... build pipeline (see Step 1.5 for extraction) ...

        const id = self.render_pipeline_count;
        self.render_pipelines[id] = .{
            .handle = handle,
            .layout = layout,
            .vertex_buffer_count = vertex_buffer_count,
        };
        self.render_pipeline_count += 1;

        // Post-conditions
        std.debug.assert(self.render_pipelines[id].handle != null);
        std.debug.assert(self.render_pipeline_count <= MAX_RENDER_PIPELINES);

        return id;
    }
};
```

#### Step 1.3: Extract Pass Operations

```zig
// src/executor/wgpu_native/passes.zig
//! GPU Pass Operations
//!
//! Manages render and compute pass state and operations.
//!
//! ## Design
//! - One active pass at a time (render OR compute)
//! - Pass state tracked explicitly
//! - All operations validate pass is active
//!
//! ## Invariants
//! - Cannot begin pass while another is active
//! - Must end pass before starting new one
//! - Draw/dispatch only valid within appropriate pass type

const std = @import("std");
const c = @import("../gpu/wgpu_c.zig");

pub const PassState = enum {
    none,
    render,
    compute,
};

pub const Passes = struct {
    state: PassState = .none,
    render_pass: c.RenderPassEncoder = null,
    compute_pass: c.ComputePassEncoder = null,
    command_encoder: c.CommandEncoder = null,

    /// Begin a render pass with the specified configuration.
    ///
    /// Pre-conditions:
    /// - No pass currently active (state == .none)
    /// - device and queue must be valid
    /// - surface_view must be valid texture view
    ///
    /// Post-conditions:
    /// - state == .render
    /// - render_pass is valid encoder
    pub fn beginRenderPass(
        self: *Passes,
        device: c.Device,
        surface_view: c.TextureView,
        clear_color: [4]f32,
        load_op: c.WGPULoadOp,
        store_op: c.WGPUStoreOp,
    ) !void {
        // Pre-conditions
        std.debug.assert(self.state == .none);
        std.debug.assert(device != null);
        std.debug.assert(surface_view != null);

        // Create command encoder
        self.command_encoder = c.wgpuDeviceCreateCommandEncoder(device, null);
        if (self.command_encoder == null) {
            return error.CommandEncoderCreationFailed;
        }

        // Build render pass descriptor
        const color_attachment = c.WGPURenderPassColorAttachment{
            .view = surface_view,
            .loadOp = load_op,
            .storeOp = store_op,
            .clearValue = .{ .r = clear_color[0], .g = clear_color[1], .b = clear_color[2], .a = clear_color[3] },
        };

        const desc = c.WGPURenderPassDescriptor{
            .colorAttachmentCount = 1,
            .colorAttachments = &color_attachment,
        };

        self.render_pass = c.wgpuCommandEncoderBeginRenderPass(self.command_encoder, &desc);
        if (self.render_pass == null) {
            return error.RenderPassCreationFailed;
        }

        self.state = .render;

        // Post-conditions
        std.debug.assert(self.state == .render);
        std.debug.assert(self.render_pass != null);
    }

    /// Draw vertices using currently bound pipeline and resources.
    ///
    /// Pre-conditions:
    /// - state == .render
    /// - vertex_count > 0
    ///
    /// Post-conditions:
    /// - Draw command recorded (no state change)
    pub fn draw(
        self: *Passes,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void {
        // Pre-conditions
        std.debug.assert(self.state == .render);
        std.debug.assert(self.render_pass != null);
        std.debug.assert(vertex_count > 0);
        std.debug.assert(instance_count > 0);

        c.wgpuRenderPassEncoderDraw(
            self.render_pass,
            vertex_count,
            instance_count,
            first_vertex,
            first_instance,
        );

        // Post-condition: state unchanged
        std.debug.assert(self.state == .render);
    }
};
```

#### Step 1.4: Extract JSON Descriptor Parsing

```zig
// src/executor/wgpu_native/descriptors.zig
//! JSON Descriptor Parsing for GPU Resources
//!
//! Parses JSON-based descriptors for pipelines, bind groups, etc.
//! Used to interpret bytecode payload descriptors at runtime.
//!
//! ## Design
//! - Bounded parsing with MAX_JSON_TOKENS limit
//! - No dynamic allocation - uses stack buffers
//! - Explicit error handling for malformed JSON
//!
//! ## Invariants
//! - Parser never exceeds MAX_JSON_TOKENS iterations
//! - All string references point into original JSON buffer

const std = @import("std");

pub const MAX_JSON_TOKENS = 1024;
pub const MAX_VERTEX_ATTRIBUTES = 16;
pub const MAX_BIND_GROUP_ENTRIES = 16;

pub const ParseError = error{
    TooManyTokens,
    UnexpectedToken,
    MissingRequiredField,
    InvalidValue,
    BufferOverflow,
};

pub const VertexAttributeDesc = struct {
    format: []const u8,
    offset: u32,
    shader_location: u32,
};

pub const VertexBufferLayoutDesc = struct {
    array_stride: u32,
    step_mode: []const u8,
    attributes: [MAX_VERTEX_ATTRIBUTES]VertexAttributeDesc,
    attribute_count: u32,
};

pub const RenderPipelineDesc = struct {
    vertex_module: []const u8,
    vertex_entry: []const u8,
    fragment_module: ?[]const u8,
    fragment_entry: ?[]const u8,
    vertex_buffers: [8]VertexBufferLayoutDesc,
    vertex_buffer_count: u32,
    primitive_topology: []const u8,
    front_face: []const u8,
    cull_mode: []const u8,
    // ... color targets, depth, etc.
};

/// Parse a render pipeline descriptor from JSON.
///
/// Pre-conditions:
/// - json must be valid UTF-8
/// - json.len > 0
///
/// Post-conditions:
/// - Returns fully populated descriptor
/// - All string slices point into original json buffer
pub fn parseRenderPipelineDescriptor(json: []const u8) ParseError!RenderPipelineDesc {
    // Pre-conditions
    std.debug.assert(json.len > 0);

    var result: RenderPipelineDesc = .{
        .vertex_module = "",
        .vertex_entry = "main",
        .fragment_module = null,
        .fragment_entry = null,
        .vertex_buffers = undefined,
        .vertex_buffer_count = 0,
        .primitive_topology = "triangle-list",
        .front_face = "ccw",
        .cull_mode = "none",
    };

    var parser = std.json.Scanner.initCompleteInput(json);
    var token_count: u32 = 0;

    // Bounded iteration - critical for safety
    for (0..MAX_JSON_TOKENS) |_| {
        const token = parser.next() catch |err| {
            return if (err == error.EndOfStream) break else ParseError.UnexpectedToken;
        };

        token_count += 1;

        switch (token) {
            .object_begin => {},
            .object_end => break,
            .string => |s| {
                // Parse field based on key
                // ... implementation ...
            },
            else => {},
        }
    } else {
        // Loop exhausted without finding end - too many tokens
        return ParseError.TooManyTokens;
    }

    // Post-conditions
    std.debug.assert(result.vertex_module.len > 0 or result.vertex_entry.len > 0);

    return result;
}
```

#### Step 1.5: Refactor Main Entry Point

```zig
// src/executor/wgpu_native_gpu.zig (refactored - ~200 lines)
//! wgpu-native GPU Backend
//!
//! Native GPU backend using wgpu-native library for cross-platform
//! WebGPU support on iOS, Android, macOS, Windows, and Linux.
//!
//! ## Architecture
//! - Context: Shared GPU context (instance, adapter, device, queue)
//! - WgpuNativeGPU: Per-animation GPU state delegating to sub-modules
//!
//! ## Sub-modules
//! - resources.zig: Buffer, texture, shader, sampler creation
//! - pipelines.zig: Render/compute pipeline creation
//! - bind_groups.zig: Bind group management
//! - passes.zig: Render/compute pass operations
//! - commands.zig: Draw, dispatch, copy commands
//! - descriptors.zig: JSON descriptor parsing
//!
//! ## Design Decisions
//! - Static allocation with bounded arrays (no runtime malloc)
//! - Resource IDs are array indices for O(1) lookup
//! - One active pass at a time (render XOR compute)

const std = @import("std");
const c = @import("../gpu/wgpu_c.zig");

// Sub-modules
const resources = @import("wgpu_native/resources.zig");
const pipelines = @import("wgpu_native/pipelines.zig");
const bind_groups = @import("wgpu_native/bind_groups.zig");
const passes = @import("wgpu_native/passes.zig");
const commands = @import("wgpu_native/commands.zig");

/// Shared GPU context - one per application.
pub const Context = struct {
    instance: c.Instance,
    adapter: c.Adapter,
    device: c.Device,
    queue: c.Queue,

    /// Initialize GPU context.
    ///
    /// Pre-conditions: None (first initialization)
    /// Post-conditions: All handles valid or error returned
    pub fn init() !Context {
        const instance = c.wgpuCreateInstance(null);
        if (instance == null) return error.InstanceCreationFailed;

        const adapter = c.requestAdapterSync(instance, null);
        if (adapter == null) {
            c.wgpuInstanceRelease(instance);
            return error.AdapterRequestFailed;
        }

        const device = c.requestDeviceSync(adapter, null);
        if (device == null) {
            c.wgpuAdapterRelease(adapter);
            c.wgpuInstanceRelease(instance);
            return error.DeviceRequestFailed;
        }

        const queue = c.wgpuDeviceGetQueue(device);

        const ctx = Context{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
        };

        // Post-conditions
        std.debug.assert(ctx.instance != null);
        std.debug.assert(ctx.adapter != null);
        std.debug.assert(ctx.device != null);
        std.debug.assert(ctx.queue != null);

        return ctx;
    }

    pub fn deinit(self: *Context) void {
        if (self.queue) |q| c.wgpuQueueRelease(q);
        if (self.device) |d| c.wgpuDeviceRelease(d);
        if (self.adapter) |a| c.wgpuAdapterRelease(a);
        if (self.instance) |i| c.wgpuInstanceRelease(i);
        self.* = .{ .instance = null, .adapter = null, .device = null, .queue = null };
    }
};

/// Per-animation GPU state.
pub const WgpuNativeGPU = struct {
    ctx: *Context,
    surface: c.Surface,
    surface_format: c.WGPUTextureFormat,
    width: u32,
    height: u32,

    // Delegated state
    resources: resources.Resources,
    pipelines: pipelines.Pipelines,
    bind_groups: bind_groups.BindGroups,
    passes: passes.Passes,

    /// Initialize per-animation GPU state.
    pub fn init(ctx: *Context, surface: c.Surface, width: u32, height: u32) !WgpuNativeGPU {
        std.debug.assert(ctx.device != null);
        std.debug.assert(surface != null);
        std.debug.assert(width > 0 and height > 0);

        const format = c.wgpuSurfaceGetPreferredFormat(surface, ctx.adapter);

        var gpu = WgpuNativeGPU{
            .ctx = ctx,
            .surface = surface,
            .surface_format = format,
            .width = width,
            .height = height,
            .resources = .{},
            .pipelines = .{},
            .bind_groups = .{},
            .passes = .{},
        };

        try gpu.configureSurface();

        return gpu;
    }

    // Delegate to sub-modules
    pub fn createBuffer(self: *WgpuNativeGPU, size: u32, usage: u32, label: ?[*:0]const u8) !u32 {
        return self.resources.createBuffer(self.ctx.device, size, usage, label);
    }

    pub fn createRenderPipeline(self: *WgpuNativeGPU, desc_json: []const u8) !u32 {
        return self.pipelines.createRenderPipelineFromDescriptor(
            self.ctx.device,
            desc_json,
            &self.resources.shaders,
            self.surface_format,
        );
    }

    // ... other delegating methods ...
};
```

#### Step 1.6: Migration Strategy

To avoid breaking changes during migration:

1. **Phase 1a**: Create new module structure with empty files
2. **Phase 1b**: Copy functions to new modules (don't delete from original)
3. **Phase 1c**: Update imports in original to use new modules
4. **Phase 1d**: Run tests to verify no regressions
5. **Phase 1e**: Remove duplicated code from original
6. **Phase 1f**: Final test pass

### Verification

```bash
# After each sub-phase:
/Users/hugo/.zvm/bin/zig build test-executor --summary all

# Full test suite after completion:
/Users/hugo/.zvm/bin/zig build test-standalone --summary all
```

---

## Phase 2: Add Bounded Iteration to All Loops (High Priority)

**Priority:** High
**Risk:** Low (adding safety, not changing logic)
**Estimated Complexity:** Medium

### Problem

Several loops in the codebase are unbounded, violating the mastery principle:
> "Bounded loops - Always use `for (0..MAX_X) |_|` with `else unreachable`"

Unbounded loops risk infinite execution on malformed input.

### Locations to Fix

#### 2.1 JSON Parsing Loops

**File:** `src/executor/wgpu_native_gpu.zig` (will be `descriptors.zig`)

```zig
// BEFORE (unsafe):
while (parser.next()) |token| {
    // Process token...
}

// AFTER (safe):
const MAX_JSON_TOKENS = 1024;
for (0..MAX_JSON_TOKENS) |_| {
    const token = parser.next() catch break;
    if (token == .eof) break;
    // Process token...
} else {
    return error.TooManyJsonTokens;
}
```

#### 2.2 Resource Iteration Loops

**File:** `src/native_api.zig`

```zig
// BEFORE (unsafe):
while (animations.items.len > 0) {
    const anim = animations.pop();
    anim.destroy();
}

// AFTER (safe):
const initial_count = animations.items.len;
for (0..MAX_ANIMATIONS) |i| {
    if (i >= initial_count) break;
    if (animations.items.len == 0) break;
    const anim = animations.pop();
    anim.destroy();
} else {
    // Should never happen if MAX_ANIMATIONS is correct
    std.debug.panic("Animation cleanup exceeded MAX_ANIMATIONS");
}
```

#### 2.3 String Processing Loops

**File:** `src/executor/wgpu_native_gpu.zig`

```zig
// BEFORE (unsafe):
var i: usize = 0;
while (i < str.len and str[i] != 0) : (i += 1) {}

// AFTER (safe):
const MAX_STRING_LEN = 4096;
var i: u32 = 0;
for (0..MAX_STRING_LEN) |_| {
    if (i >= str.len or str[i] == 0) break;
    i += 1;
} else {
    return error.StringTooLong;
}
```

### Implementation Checklist

| Location | Current Pattern | Fix Required |
|----------|-----------------|--------------|
| `wgpu_native_gpu.zig:parseVertexBufferLayouts` | `while (parser.next())` | Bounded iteration |
| `wgpu_native_gpu.zig:parseBindGroupEntries` | `while (parser.next())` | Bounded iteration |
| `wgpu_native_gpu.zig:parseColorTargets` | `while (parser.next())` | Bounded iteration |
| `native_api.zig:pngine_shutdown` | `while (animations.len > 0)` | Bounded iteration |
| `native_api.zig:findSlot` | `for (slots) \|s\|` | Already bounded ✓ |

### New Constants to Add

```zig
// src/executor/wgpu_native/descriptors.zig
pub const MAX_JSON_TOKENS = 1024;
pub const MAX_JSON_DEPTH = 32;
pub const MAX_STRING_VALUE_LEN = 4096;

// src/native_api.zig
pub const MAX_CLEANUP_ITERATIONS = MAX_ANIMATIONS * 2; // Safety margin
```

---

## Phase 3: Add Pre/Post Assertions (Medium Priority)

**Priority:** Medium
**Risk:** Very Low (debug-only, no runtime impact in release)
**Estimated Complexity:** Low

### Principle

> "2+ assertions per function - Pre-conditions and post-conditions"

Assertions catch bugs early and document contracts.

### Assertion Patterns

#### 3.1 Resource Creation Functions

```zig
pub fn createBuffer(self: *Resources, device: c.Device, size: u32, usage: u32) !u32 {
    // === PRE-CONDITIONS ===
    std.debug.assert(device != null);           // Valid device
    std.debug.assert(size > 0);                 // Non-zero size
    std.debug.assert(size % 4 == 0);            // WebGPU alignment
    std.debug.assert(self.buffer_count < MAX_BUFFERS); // Capacity available

    const id = self.buffer_count;
    // ... creation logic ...

    // === POST-CONDITIONS ===
    std.debug.assert(self.buffers[id].handle != null); // Handle created
    std.debug.assert(self.buffer_count == id + 1);     // Count incremented
    std.debug.assert(self.buffer_count <= MAX_BUFFERS); // Within bounds

    return id;
}
```

#### 3.2 State Transition Functions

```zig
pub fn beginRenderPass(self: *Passes, ...) !void {
    // === PRE-CONDITIONS ===
    std.debug.assert(self.state == .none);      // No active pass
    std.debug.assert(self.render_pass == null); // Clean state
    std.debug.assert(device != null);
    std.debug.assert(surface_view != null);

    // ... begin pass logic ...

    // === POST-CONDITIONS ===
    std.debug.assert(self.state == .render);    // State transitioned
    std.debug.assert(self.render_pass != null); // Encoder created
    std.debug.assert(self.command_encoder != null);
}

pub fn endRenderPass(self: *Passes) !void {
    // === PRE-CONDITIONS ===
    std.debug.assert(self.state == .render);    // Must be in render pass
    std.debug.assert(self.render_pass != null);

    // ... end pass logic ...

    // === POST-CONDITIONS ===
    std.debug.assert(self.state == .none);      // State reset
    std.debug.assert(self.render_pass == null); // Encoder released
}
```

#### 3.3 Lookup Functions

```zig
pub fn getBuffer(self: *Resources, id: u32) ?*BufferEntry {
    // === PRE-CONDITIONS ===
    std.debug.assert(id < MAX_BUFFERS);         // Valid ID range

    if (id >= self.buffer_count) return null;

    const entry = &self.buffers[id];

    // === POST-CONDITIONS ===
    // If returning non-null, handle must be valid
    if (entry.handle != null) {
        std.debug.assert(entry.size > 0);
    }

    return if (entry.handle != null) entry else null;
}
```

### Functions Requiring Assertions

| File | Function | Pre-conditions | Post-conditions |
|------|----------|----------------|-----------------|
| `resources.zig` | `createBuffer` | device, size>0, capacity | handle valid, count++ |
| `resources.zig` | `createTexture` | device, dims>0, capacity | handle valid, count++ |
| `resources.zig` | `createShaderModule` | device, code.len>0 | handle valid |
| `pipelines.zig` | `createRenderPipeline` | device, desc valid | handle valid |
| `pipelines.zig` | `createComputePipeline` | device, desc valid | handle valid |
| `bind_groups.zig` | `createBindGroup` | device, layout valid | handle valid |
| `passes.zig` | `beginRenderPass` | state==none, device | state==render |
| `passes.zig` | `endRenderPass` | state==render | state==none |
| `passes.zig` | `beginComputePass` | state==none | state==compute |
| `passes.zig` | `endComputePass` | state==compute | state==none |
| `passes.zig` | `draw` | state==render, counts>0 | (no state change) |
| `passes.zig` | `dispatch` | state==compute, counts>0 | (no state change) |
| `wgpu_c.zig` | `requestAdapterSync` | instance valid | adapter or null |
| `wgpu_c.zig` | `requestDeviceSync` | adapter valid | device or null |
| `native_api.zig` | `pngine_create` | bytecode valid, layer valid | anim or null |
| `native_api.zig` | `pngine_render` | anim valid | 0 or error code |
| `init.zig` | `emitInitMacro` | ast valid, emitter valid | bytecode emitted |

---

## Phase 4: Fix Type Sizing (Low Priority)

**Priority:** Low
**Risk:** Very Low
**Estimated Complexity:** Low

### Principle

> "Explicitly-sized types - Use u32, i64, not usize (except slice indexing)"

### Locations to Fix

#### 4.1 Function Parameters

```zig
// BEFORE:
pub fn mapBufferUsage(usage: usize) u32 { ... }

// AFTER:
pub fn mapBufferUsage(usage: u32) u32 { ... }
```

#### 4.2 Loop Counters

```zig
// BEFORE:
var i: usize = 0;
while (i < count) : (i += 1) { ... }

// AFTER:
for (0..@as(u32, @intCast(count))) |i| { ... }
// Or if count is already u32:
for (0..count) |i| { ... }
```

#### 4.3 Size Calculations

```zig
// BEFORE:
const total_size: usize = width * height * 4;

// AFTER:
const total_size: u32 = width * height * 4;
// Or if overflow is possible:
const total_size: u64 = @as(u64, width) * @as(u64, height) * 4;
```

### Checklist

| File | Location | Current | Target |
|------|----------|---------|--------|
| `wgpu_c.zig` | `mapBufferUsage` param | `usize` | `u32` |
| `wgpu_c.zig` | `mapLoadOp` param | `usize` | `u32` |
| `wgpu_c.zig` | `mapStoreOp` param | `usize` | `u32` |
| `native_api.zig` | loop counters | `usize` | `u32` |
| `wgpu_native_gpu.zig` | size calculations | mixed | `u32`/`u64` |

---

## Phase 5: Refactor Long Functions (Medium Priority)

**Priority:** Medium
**Risk:** Medium (refactoring logic)
**Estimated Complexity:** Medium

### Principle

> "Functions ≤ 70 lines (exception: state machines with labeled switch)"

### Functions to Split

#### 5.1 `createRenderPipeline` (~150 lines → 3 functions)

```zig
// BEFORE: One 150-line function

// AFTER: Split into focused helpers

/// Parse and validate render pipeline descriptor.
fn parseRenderPipelineDesc(json: []const u8) !RenderPipelineDesc {
    // ~40 lines - parsing logic
}

/// Build vertex state from parsed descriptor.
fn buildVertexState(
    desc: *const RenderPipelineDesc,
    shaders: *const ShaderTable,
) !c.WGPUVertexState {
    // ~30 lines - vertex buffer layout construction
}

/// Build fragment state from parsed descriptor.
fn buildFragmentState(
    desc: *const RenderPipelineDesc,
    shaders: *const ShaderTable,
    format: c.WGPUTextureFormat,
) !c.WGPUFragmentState {
    // ~25 lines - color target construction
}

/// Create render pipeline from descriptor.
pub fn createRenderPipeline(
    self: *Pipelines,
    device: c.Device,
    desc_json: []const u8,
    shaders: *const ShaderTable,
    format: c.WGPUTextureFormat,
) !u32 {
    // ~30 lines - orchestration
    const desc = try parseRenderPipelineDesc(desc_json);
    const vertex_state = try buildVertexState(&desc, shaders);
    const fragment_state = try buildFragmentState(&desc, shaders, format);
    // ... create pipeline ...
}
```

#### 5.2 `createBindGroup` (~120 lines → 2 functions)

```zig
/// Parse bind group entries from JSON.
fn parseBindGroupEntries(json: []const u8) ![]BindGroupEntryDesc {
    // ~50 lines
}

/// Create bind group from parsed entries.
pub fn createBindGroup(...) !u32 {
    // ~50 lines
}
```

#### 5.3 `beginRenderPass` (~100 lines → 2 functions)

```zig
/// Build render pass descriptor from parameters.
fn buildRenderPassDescriptor(...) c.WGPURenderPassDescriptor {
    // ~40 lines
}

/// Begin render pass with descriptor.
pub fn beginRenderPass(...) !void {
    // ~40 lines
}
```

#### 5.4 `pngine_create` (~100 lines → 3 functions)

```zig
/// Validate and parse bytecode.
fn validateBytecode(data: []const u8) !*const Module {
    // ~25 lines
}

/// Initialize GPU resources for animation.
fn initGpuResources(ctx: *Context, surface: c.Surface, width: u32, height: u32) !*WgpuNativeGPU {
    // ~30 lines
}

/// Create animation instance.
pub export fn pngine_create(...) ?*Animation {
    // ~35 lines - orchestration
}
```

---

## Phase 6: Documentation Improvements (Low Priority)

**Priority:** Low
**Risk:** None
**Estimated Complexity:** Low

### Ensure All Modules Have

1. **Module-level documentation** (`//!` at top)
2. **Design section** explaining key decisions
3. **Invariants section** listing what must always be true
4. **Public function documentation** (`///`)

### Template

```zig
//! Module Name - Brief Description
//!
//! Longer explanation of what this module does and why.
//!
//! ## Design
//! - Key design decision 1
//! - Key design decision 2
//!
//! ## Invariants
//! - Invariant 1 (e.g., "resource count never exceeds MAX")
//! - Invariant 2 (e.g., "all handles are valid or null")
//!
//! ## Usage
//! ```zig
//! const module = @import("module.zig");
//! // Example usage...
//! ```

const std = @import("std");

/// Brief description of function.
///
/// Longer explanation if needed.
///
/// Pre-conditions:
/// - Condition 1
/// - Condition 2
///
/// Post-conditions:
/// - Condition 1
/// - Condition 2
///
/// Complexity: O(n) where n is...
pub fn exampleFunction() void {}
```

---

## Phase 7: Add Missing Tests (Low Priority)

**Priority:** Low
**Risk:** None
**Estimated Complexity:** Medium

### Test Coverage Gaps

#### 7.1 Bounded Loop Edge Cases

```zig
test "JSON parsing respects MAX_JSON_TOKENS" {
    // Generate JSON with exactly MAX_JSON_TOKENS tokens
    var json_buf: [MAX_JSON_TOKENS * 10]u8 = undefined;
    const json = generateLargeJson(&json_buf, MAX_JSON_TOKENS);

    // Should succeed
    const result = try parseRenderPipelineDescriptor(json);
    _ = result;
}

test "JSON parsing fails on too many tokens" {
    // Generate JSON with MAX_JSON_TOKENS + 1 tokens
    var json_buf: [(MAX_JSON_TOKENS + 100) * 10]u8 = undefined;
    const json = generateLargeJson(&json_buf, MAX_JSON_TOKENS + 100);

    // Should fail with TooManyTokens
    const result = parseRenderPipelineDescriptor(json);
    try std.testing.expectError(error.TooManyTokens, result);
}
```

#### 7.2 Assertion Verification (Debug Builds)

```zig
test "createBuffer asserts on zero size" {
    if (!std.debug.runtime_safety) return; // Skip in release

    var resources = Resources{};
    // This should trigger assertion failure in debug mode
    // We can't easily test this, but document the expected behavior
}
```

#### 7.3 State Machine Transitions

```zig
test "pass state transitions are valid" {
    var passes = Passes{};

    // Initial state
    try std.testing.expectEqual(PassState.none, passes.state);

    // Begin render pass
    try passes.beginRenderPass(...);
    try std.testing.expectEqual(PassState.render, passes.state);

    // Can't begin another pass while one is active
    // (assertion would fire in debug)

    // End render pass
    try passes.endRenderPass();
    try std.testing.expectEqual(PassState.none, passes.state);

    // Now can begin compute pass
    try passes.beginComputePass(...);
    try std.testing.expectEqual(PassState.compute, passes.state);
}
```

---

## Implementation Order

### Week 1: Critical Safety (Phases 2, 3)

| Day | Task | Verification |
|-----|------|--------------|
| 1 | Add bounded iteration to JSON parsing | `test-executor` passes |
| 2 | Add bounded iteration to remaining loops | `test-executor` passes |
| 3 | Add pre-conditions to resource creation | `test-executor` passes |
| 4 | Add post-conditions to resource creation | `test-executor` passes |
| 5 | Add assertions to pass operations | `test-standalone` passes |

### Week 2: Refactoring (Phase 1)

| Day | Task | Verification |
|-----|------|--------------|
| 1 | Create module structure, empty files | Compiles |
| 2 | Extract `resources.zig` | `test-executor` passes |
| 3 | Extract `pipelines.zig` | `test-executor` passes |
| 4 | Extract `passes.zig`, `commands.zig` | `test-executor` passes |
| 5 | Extract `descriptors.zig`, `bind_groups.zig` | `test-standalone` passes |

### Week 3: Polish (Phases 4, 5, 6)

| Day | Task | Verification |
|-----|------|--------------|
| 1 | Fix type sizing issues | `test-standalone` passes |
| 2 | Split `createRenderPipeline` | `test-executor` passes |
| 3 | Split remaining long functions | `test-executor` passes |
| 4 | Add documentation to new modules | Code review |
| 5 | Add edge case tests | `test-standalone` passes |

---

## Verification Commands

```bash
# After each change:
/Users/hugo/.zvm/bin/zig build test-executor --summary all

# After Phase 1 completion:
/Users/hugo/.zvm/bin/zig build test-standalone --summary all

# Full verification:
/Users/hugo/.zvm/bin/zig build test --summary all

# iOS build verification:
cd native/ios/PngineTestApp && xcodebuild -scheme PngineTestApp -destination 'platform=iOS Simulator,name=iPhone 16' build

# Check for any usize usage (should be minimal):
grep -r "usize" src/executor/wgpu_native*.zig | grep -v "// slice index"
```

---

## Risk Mitigation

### Phase 1 (File Split) Risks

| Risk | Mitigation |
|------|------------|
| Import cycles | Plan module dependencies upfront |
| Missing exports | Run tests after each file extraction |
| Build breakage | Keep original file until migration complete |

### Phase 2 (Bounded Loops) Risks

| Risk | Mitigation |
|------|------------|
| False positives | Choose MAX values with 2x safety margin |
| Performance impact | `for` loops compile to same code as `while` |
| Logic changes | Only add bounds, don't change loop body |

### Phase 3 (Assertions) Risks

| Risk | Mitigation |
|------|------------|
| Debug/Release divergence | Assertions are debug-only by design |
| Over-assertion | Focus on actual invariants, not obvious facts |
| Test failures | Assertions reveal bugs, fix the bugs |

---

## Success Criteria

### Phase 1 Complete When:
- [ ] `wgpu_native_gpu.zig` is ≤300 lines
- [ ] 6 sub-modules created in `wgpu_native/`
- [ ] All tests pass
- [ ] No functionality changes

### Phase 2 Complete When:
- [ ] Zero unbounded `while` loops in modified files
- [ ] All JSON parsing has MAX_JSON_TOKENS bound
- [ ] `else` clause on all bounded loops

### Phase 3 Complete When:
- [ ] All public functions have ≥2 assertions
- [ ] Pre-conditions document input requirements
- [ ] Post-conditions document output guarantees

### Phase 4 Complete When:
- [ ] No `usize` except for slice indexing
- [ ] All sizes are `u32` or `u64` as appropriate

### Phase 5 Complete When:
- [ ] No function exceeds 70 lines (except state machines)
- [ ] Helper functions are private (`fn` not `pub fn`)

### Phase 6 Complete When:
- [ ] All modules have `//!` documentation
- [ ] All public functions have `///` documentation

### Phase 7 Complete When:
- [ ] Edge case tests for bounded iteration
- [ ] State transition tests for passes
- [ ] All new tests pass
