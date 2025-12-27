# Multiplatform Command Buffer Architecture

## Design Philosophy

**Goal**: Same PNGB bytecode runs on Web, iOS, Android, and Desktop with a unified Zig runtime.

**Key Insight**: WebGPU IS the abstraction layer. With Dawn (Google) and Mach (Zig) providing WebGPU on native platforms, we don't need separate Metal/Vulkan backends. We just need to:
1. Port the command dispatcher from JS to Zig
2. Abstract only I/O operations (image loading, video)

**Principle**: One Zig codebase compiles to WASM (browser) and native (desktop/mobile).

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Bytecode (.pngb)                         │
│  - Same format everywhere                                   │
│  - WGSL shaders (native WebGPU support)                     │
│  - No transpilation needed                                  │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│               Pngine Runtime (100% Zig)                     │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Bytecode Parser + State Manager                     │   │
│  │  (same code compiles to WASM and native)             │   │
│  └─────────────────────────────────────────────────────┘   │
│                              ↓                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Command Dispatcher (Zig)                            │   │
│  │  - Dispatches opcodes directly                       │   │
│  │  - Calls WebGPU API                                  │   │
│  │  - Same code on all platforms                        │   │
│  └─────────────────────────────────────────────────────┘   │
│                              ↓                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Platform I/O (thin abstraction)                     │   │
│  │  - Web: JS imports for image/video                   │   │
│  │  - Native: stb_image, ffmpeg, etc.                   │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌───────────────────┬───────────────────┬───────────────────┐
│   Browser WebGPU  │   Dawn (C++)      │   Mach (Zig)      │
│   (via JS binds)  │   (via zgpu)      │   (native Zig)    │
│                   │                   │                   │
│   Chrome, Firefox │   Windows, Linux  │   macOS, Linux    │
│   Safari, Edge    │   Android, iOS    │                   │
└───────────────────┴───────────────────┴───────────────────┘
```

---

## What Changes vs Current Architecture

| Component | Current (JS-heavy) | New (Zig-native) |
|-----------|-------------------|------------------|
| Command dispatch | `gpu.js` (1221 lines) | `executor/dispatcher.zig` |
| Resource management | JS Maps | Zig hash maps |
| Descriptor parsing | JS binary decoders | Zig (already exists) |
| WebGPU calls | JS `device.create*()` | Zig via WebGPU bindings |
| Bundle size (web) | 9.3KB gzip | ~2KB gzip (bindings only) |
| Native support | None | Full (Dawn/Mach) |

## What Stays the Same

1. **Bytecode format (PNGB)** - Already platform-agnostic
2. **DSL syntax** - Same `.pngine` files work everywhere
3. **WGSL shaders** - Native WebGPU support, no transpilation
4. **Core opcodes** - Same semantics, Zig dispatcher instead of JS
5. **Binary descriptors** - Keep current format (compact, fast)

---

## Command Set Design

### Clean Opcode Set (21 opcodes)

With JS-specific opcodes removed, the core set is portable:

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

I/O Operations (0x30-0x31):  // Platform-specific implementation
  0x30 LOAD_IMAGE         [id:u16] [data_ptr:u32] [data_len:u32]
  0x31 BIND_VIDEO_FRAME   [video_id:u16] [tex_id:u16]

Control (0xF0, 0xFF):
  0xF0 SUBMIT             (no args)
  0xFF END                (no args)
```

### Removed Opcodes (JS-specific, not portable)

| Opcode | Why Remove | Replacement |
|--------|------------|-------------|
| `create_typed_array` | JS TypedArray concept | Use Zig slices + WRITE_BUFFER |
| `fill_random` | JS Math.random() | Generate in Zig PRNG at compile time |
| `fill_expression` | JS eval() | Evaluate at compile time in DSL |
| `fill_constant` | JS array fill | Pre-compute, store in data section |
| `write_buffer_from_array` | JS TypedArray | Use WRITE_BUFFER |
| `init_wasm_module` | Nested WASM | Not portable, remove feature |
| `call_wasm_func` | Nested WASM | Not portable, remove feature |
| `create_image_bitmap` | Web-only API | Replace with LOAD_IMAGE |
| `copy_external_image` | Web-only API | Handled by LOAD_IMAGE |

---

## Implementation Plan

### Phase 1: Remove JS-Specific Opcodes

**Goal**: Clean up command buffer to only contain portable opcodes.

**Files to change:**
- `src/bytecode/opcodes.zig` - Remove JS-specific opcodes
- `src/executor/command_buffer.zig` - Remove emission functions
- `src/dsl/emitter/resources.zig` - Use WRITE_BUFFER for data
- `npm/pngine/src/gpu.js` - Remove handlers (temporary, until Phase 3)

**Data generation strategy:**
```zig
// Instead of: fill_random in JS
// Do: Generate random data at compile time in Zig

// In DSL emitter
fn emitRandomData(self: *Emitter, size: u32, seed: u64) !void {
    var prng = std.rand.DefaultPrng.init(seed);
    const data = try self.allocator.alloc(u8, size);
    prng.fill(data);

    // Store in data section, emit WRITE_BUFFER
    const data_offset = try self.data_section.append(data);
    try self.emitWriteBuffer(buffer_id, 0, data_offset, size);
}
```

### Phase 2: Abstract WebGPU Binding

**Goal**: Create unified WebGPU interface that compiles to both WASM and native.

```zig
// src/gpu/webgpu.zig - Unified interface
pub const WebGPU = struct {
    const Self = @This();

    // Platform-specific backend
    backend: Backend,

    pub const Backend = switch (builtin.target.os.tag) {
        .freestanding => @import("backends/wasm.zig").WasmBackend,
        else => @import("backends/native.zig").NativeBackend,
    };

    // Unified API (same signatures everywhere)
    pub fn createBuffer(self: *Self, desc: BufferDescriptor) !Buffer {
        return self.backend.createBuffer(desc);
    }

    pub fn createTexture(self: *Self, desc: TextureDescriptor) !Texture {
        return self.backend.createTexture(desc);
    }

    pub fn createShaderModule(self: *Self, wgsl: []const u8) !ShaderModule {
        return self.backend.createShaderModule(wgsl);
    }

    pub fn createRenderPipeline(self: *Self, desc: RenderPipelineDescriptor) !RenderPipeline {
        return self.backend.createRenderPipeline(desc);
    }

    // ... etc
};

// src/gpu/backends/wasm.zig - Browser backend (calls JS imports)
pub const WasmBackend = struct {
    // JS imports
    extern "webgpu" fn wgpu_create_buffer(size: u32, usage: u32) u32;
    extern "webgpu" fn wgpu_create_texture(desc_ptr: [*]const u8, desc_len: u32) u32;
    extern "webgpu" fn wgpu_create_shader(code_ptr: [*]const u8, code_len: u32) u32;
    // ...

    pub fn createBuffer(self: *WasmBackend, desc: BufferDescriptor) !Buffer {
        const handle = wgpu_create_buffer(desc.size, @intFromEnum(desc.usage));
        return Buffer{ .handle = handle };
    }
};

// src/gpu/backends/native.zig - Native backend (calls Mach/Dawn)
pub const NativeBackend = struct {
    device: mach.gpu.Device,
    queue: mach.gpu.Queue,

    pub fn createBuffer(self: *NativeBackend, desc: BufferDescriptor) !Buffer {
        const gpu_desc = mach.gpu.Buffer.Descriptor{
            .size = desc.size,
            .usage = translateUsage(desc.usage),
        };
        return Buffer{ .handle = self.device.createBuffer(&gpu_desc) };
    }
};
```

### Phase 3: Port Dispatcher to Zig

**Goal**: Move command dispatch logic from JS to Zig.

The dispatcher already exists in `executor/dispatcher.zig` with mock backend. Port it to use real WebGPU:

```zig
// src/executor/dispatcher.zig
pub const Dispatcher = struct {
    gpu: *WebGPU,
    resources: ResourceTable,

    pub fn execute(self: *Dispatcher, bytecode: []const u8) !void {
        var reader = BytecodeReader.init(bytecode);

        while (reader.hasMore()) {
            const cmd = reader.readOpcode();
            try self.dispatch(cmd, &reader);
        }
    }

    fn dispatch(self: *Dispatcher, cmd: Opcode, reader: *BytecodeReader) !void {
        switch (cmd) {
            .create_buffer => {
                const id = reader.readU16();
                const size = reader.readU32();
                const usage = reader.readU8();

                const buffer = try self.gpu.createBuffer(.{
                    .size = size,
                    .usage = @enumFromInt(usage),
                });
                try self.resources.put(id, .{ .buffer = buffer });
            },

            .create_shader => {
                const id = reader.readU16();
                const code_ptr = reader.readU32();
                const code_len = reader.readU32();
                const wgsl = self.getDataSlice(code_ptr, code_len);

                const shader = try self.gpu.createShaderModule(wgsl);
                try self.resources.put(id, .{ .shader = shader });
            },

            .begin_render_pass => {
                const color_id = reader.readU16();
                const load_op = reader.readU8();
                const store_op = reader.readU8();
                const depth_id = reader.readU16();

                const color_view = self.resources.getTextureView(color_id);
                self.current_pass = try self.gpu.beginRenderPass(.{
                    .color_attachments = &.{.{
                        .view = color_view,
                        .load_op = @enumFromInt(load_op),
                        .store_op = @enumFromInt(store_op),
                    }},
                });
            },

            .draw => {
                const vertex_count = reader.readU32();
                const instance_count = reader.readU32();
                const first_vertex = reader.readU32();
                const first_instance = reader.readU32();

                self.current_pass.draw(vertex_count, instance_count, first_vertex, first_instance);
            },

            .end_pass => {
                self.current_pass.end();
                self.current_pass = null;
            },

            .submit => {
                const command_buffer = self.encoder.finish();
                self.gpu.queue.submit(&.{command_buffer});
            },

            // ... other opcodes
        }
    }
};
```

### Phase 4: Platform I/O Layer

**Goal**: Abstract only I/O operations that differ between platforms.

```zig
// src/platform/io.zig
pub const IO = struct {
    const Self = @This();

    backend: Backend,

    pub const Backend = switch (builtin.target.os.tag) {
        .freestanding => WebIO,
        else => NativeIO,
    };

    pub fn loadImage(self: *Self, data: []const u8) !Image {
        return self.backend.loadImage(data);
    }

    pub fn getVideoFrame(self: *Self, video_id: u16) ?VideoFrame {
        return self.backend.getVideoFrame(video_id);
    }
};

// Web I/O - calls JS imports
pub const WebIO = struct {
    extern "io" fn js_load_image(ptr: [*]const u8, len: u32) u32;
    extern "io" fn js_get_video_frame(id: u16) u32;
    extern "io" fn js_get_image_data(handle: u32, out_ptr: [*]u8) void;

    pub fn loadImage(data: []const u8) !Image {
        const handle = js_load_image(data.ptr, @intCast(data.len));
        if (handle == 0) return error.ImageLoadFailed;
        return Image{ .handle = handle };
    }

    pub fn getVideoFrame(video_id: u16) ?VideoFrame {
        const handle = js_get_video_frame(video_id);
        if (handle == 0) return null;
        return VideoFrame{ .handle = handle };
    }
};

// Native I/O - uses stb_image, etc.
pub const NativeIO = struct {
    const stb = @cImport(@cInclude("stb_image.h"));

    pub fn loadImage(data: []const u8) !Image {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var channels: c_int = undefined;

        const pixels = stb.stbi_load_from_memory(
            data.ptr, @intCast(data.len),
            &width, &height, &channels, 4
        ) orelse return error.ImageLoadFailed;

        return Image{
            .width = @intCast(width),
            .height = @intCast(height),
            .pixels = pixels[0..@intCast(width * height * 4)],
        };
    }

    pub fn getVideoFrame(video_id: u16) ?VideoFrame {
        // Native video decoding (ffmpeg, etc.)
        _ = video_id;
        return null; // TODO: implement
    }
};
```

### Phase 5: Simplified Web Runtime

**Goal**: Reduce JS to thin WebGPU bindings (~100 lines).

```javascript
// npm/pngine/src/gpu-bindings.js (~100 lines)
export class WebGPUBindings {
  constructor(device, queue, memory) {
    this.device = device;
    this.queue = queue;
    this.memory = memory;  // WASM memory
    this.resources = new Map();
  }

  // Resource creation (called from WASM)
  wgpu_create_buffer(size, usage) {
    const buffer = this.device.createBuffer({ size, usage });
    const id = this.nextId++;
    this.resources.set(id, buffer);
    return id;
  }

  wgpu_create_texture(descPtr, descLen) {
    const desc = this.readDescriptor(descPtr, descLen);
    const texture = this.device.createTexture(desc);
    const id = this.nextId++;
    this.resources.set(id, texture);
    return id;
  }

  wgpu_create_shader(codePtr, codeLen) {
    const code = this.readString(codePtr, codeLen);
    const module = this.device.createShaderModule({ code });
    const id = this.nextId++;
    this.resources.set(id, module);
    return id;
  }

  // Pass operations
  wgpu_begin_render_pass(colorId, loadOp, storeOp) {
    const view = this.resources.get(colorId);
    this.encoder = this.device.createCommandEncoder();
    this.pass = this.encoder.beginRenderPass({
      colorAttachments: [{
        view,
        loadOp: ['clear', 'load'][loadOp],
        storeOp: ['store', 'discard'][storeOp],
      }]
    });
  }

  wgpu_draw(vertexCount, instanceCount, firstVertex, firstInstance) {
    this.pass.draw(vertexCount, instanceCount, firstVertex, firstInstance);
  }

  wgpu_end_pass() {
    this.pass.end();
  }

  wgpu_submit() {
    this.queue.submit([this.encoder.finish()]);
  }

  // I/O operations (browser-specific)
  async js_load_image(dataPtr, dataLen) {
    const data = new Uint8Array(this.memory.buffer, dataPtr, dataLen);
    const blob = new Blob([data]);
    const bitmap = await createImageBitmap(blob);
    const id = this.nextId++;
    this.images.set(id, bitmap);
    return id;
  }

  js_get_video_frame(videoId) {
    const frame = this.videoFrames.get(videoId);
    if (!frame) return 0;

    const texture = this.device.importExternalTexture({ source: frame });
    const id = this.nextId++;
    this.resources.set(id, texture);
    return id;
  }

  // Helpers
  readString(ptr, len) {
    return new TextDecoder().decode(new Uint8Array(this.memory.buffer, ptr, len));
  }

  readDescriptor(ptr, len) {
    // Binary descriptor parsing (keep current format)
    const bytes = new Uint8Array(this.memory.buffer, ptr, len);
    return this.parseDescriptor(bytes);
  }
}
```

---

## Build Configuration

```zig
// build.zig
pub fn build(b: *std.Build) void {
    // WASM target (browser)
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm = b.addExecutable(.{
        .name = "pngine",
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm.rdynamic = true;
    wasm.entry = .disabled;

    // Native targets (desktop/mobile)
    const native_targets = .{
        .{ .os = .macos, .cpu = .aarch64 },
        .{ .os = .macos, .cpu = .x86_64 },
        .{ .os = .linux, .cpu = .x86_64 },
        .{ .os = .linux, .cpu = .aarch64 },
        .{ .os = .windows, .cpu = .x86_64 },
        .{ .os = .windows, .cpu = .aarch64 },
        .{ .os = .ios, .cpu = .aarch64 },
        // Android requires NDK setup
    };

    inline for (native_targets) |t| {
        const target = b.resolveTargetQuery(.{
            .cpu_arch = t.cpu,
            .os_tag = t.os,
        });

        const exe = b.addExecutable(.{
            .name = "pngine",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        });

        // Link WebGPU implementation
        if (use_mach) {
            exe.addModule("mach", mach_dep.module("mach"));
        } else {
            exe.linkSystemLibrary("dawn");
        }

        b.installArtifact(exe);
    }
}
```

---

## Binary Size Comparison

| Component | Current | After Refactor |
|-----------|---------|----------------|
| WASM runtime | 57KB | ~60KB (includes dispatcher) |
| JS bundle (gzip) | 9.3KB | ~2KB (bindings only) |
| **Total web** | **66KB** | **~62KB** |
| Native binary | N/A | ~1MB (with Dawn/Mach) |

---

## Migration Path

### Step 1: Parallel Implementation
- Keep current JS dispatcher working
- Build Zig dispatcher alongside
- Test both produce identical results

### Step 2: Feature Flag
```javascript
// Toggle between JS and WASM dispatcher
const USE_ZIG_DISPATCHER = true;

if (USE_ZIG_DISPATCHER) {
  wasm.execute(bytecode);  // Zig handles everything
} else {
  dispatcher.execute(bytecode);  // Current JS path
}
```

### Step 3: Remove JS Dispatcher
- Once Zig dispatcher is proven, remove `gpu.js`
- Keep only `gpu-bindings.js` (~100 lines)

### Step 4: Native Builds
- Add Mach/Dawn as build dependencies
- Test on macOS first (easiest)
- Expand to other platforms

---

## Success Criteria

1. **Same bytecode** runs on Web, macOS, Linux, Windows
2. **No shader transpilation** - WGSL works natively via WebGPU
3. **Web bundle < 3KB gzip** (bindings only)
4. **All examples work** on both web and native
5. **Single Zig codebase** for dispatcher logic

---

## Future Extensions

Once multiplatform works:

1. **Mobile**: iOS and Android via Dawn
2. **Embedded**: Raspberry Pi via Dawn/Vulkan
3. **XR**: WebXR on web, OpenXR on native
4. **Compute**: Shared GPU compute across platforms

---

## Related Documents

- `docs/video-support-plan.md` - Video texture handling
- `docs/command-buffer-refactor-plan.md` - JS size optimization (superseded by this plan)
- `docs/js-api-refactor-plan.md` - Original API refactor vision
