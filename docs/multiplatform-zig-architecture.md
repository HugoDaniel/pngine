# PNGine Multiplatform Architecture - Unified Zig Core

**Status**: Draft
**Supersedes**: `ios-viewer-plan.md`, `ios-viewer-zig-plan.md`
**Key Insight**: One Zig codebase, multiple GPU backends, platform-specific bindings only at the edges

## Executive Summary

PNGine's architecture already has the right abstraction: `Dispatcher(BackendType)` is generic over any GPU backend. Instead of rewriting core logic per platform:

1. **Reuse** the existing Zig dispatcher, bytecode parser, and handler modules everywhere
2. **Create one new backend**: `WgpuNativeGPU` that calls wgpu-native's C API
3. **Platform bindings** are thin wrappers (~300 LOC each) for surface creation and lifecycle

This gives us iOS, Android, macOS, Windows, and Linux native support with ~500 lines of shared GPU code.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              BUILD TIME                                      │
│                                                                              │
│    .pngine source → Compiler (Zig) → .pngb bytecode → embed in .png         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ Distributed (PNG file with embedded bytecode)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              RUNTIME                                         │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     SHARED ZIG CORE (100% reused)                       ││
│  │  ┌─────────────────────────────────────────────────────────────────────┐││
│  │  │  bytecode/format.zig     - PNGB parsing                             │││
│  │  │  bytecode/opcodes.zig    - Opcode definitions                       │││
│  │  │  executor/dispatcher.zig - Generic Dispatcher(BackendType)          │││
│  │  │  executor/dispatcher/*   - Handler modules                          │││
│  │  └─────────────────────────────────────────────────────────────────────┘││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│              ┌─────────────────────┼─────────────────────┐                  │
│              ▼                     ▼                     ▼                  │
│  ┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐         │
│  │   WasmGPU         │ │  WgpuNativeGPU    │ │   MockGPU         │         │
│  │   (web)           │ │  (all native)     │ │   (tests)         │         │
│  │                   │ │                   │ │                   │         │
│  │ extern → JS       │ │ @cImport wgpu.h   │ │ records calls     │         │
│  │ WebGPU API        │ │ C function calls  │ │ for assertions    │         │
│  └─────────┬─────────┘ └─────────┬─────────┘ └───────────────────┘         │
│            │                     │                                          │
│            ▼                     ▼                                          │
│  ┌───────────────────┐ ┌───────────────────────────────────────────┐       │
│  │   gpu.js          │ │   wgpu-native (Rust, pre-compiled)        │       │
│  │   (JS runtime)    │ │   - Metal (iOS, macOS)                    │       │
│  │                   │ │   - Vulkan (Android, Linux, Windows)      │       │
│  │                   │ │   - DX12 (Windows)                        │       │
│  └─────────┬─────────┘ └─────────┬─────────────────────────────────┘       │
│            │                     │                                          │
│            ▼                     ▼                                          │
│  ┌───────────────────┐ ┌───────────────────────────────────────────┐       │
│  │   Browser WebGPU  │ │   Native GPU                               │       │
│  └───────────────────┘ └───────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Code Reuse Matrix

| Component | Web | iOS | Android | macOS | Windows | Linux | Shared? |
|-----------|-----|-----|---------|-------|---------|-------|---------|
| Bytecode parser | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **100%** |
| Dispatcher | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **100%** |
| Handler modules | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **100%** |
| WasmGPU backend | ✅ | - | - | - | - | - | Web only |
| WgpuNativeGPU | - | ✅ | ✅ | ✅ | ✅ | ✅ | **All native** |
| Platform bindings | JS | Swift | Kotlin | Swift | C# | C | Per-platform |

**Result**:
- ~4,000 LOC shared core (bytecode, dispatcher, handlers)
- ~500 LOC WgpuNativeGPU backend (shared across all native)
- ~300 LOC per platform binding

---

## Directory Structure

```
src/
├── bytecode/                    # SHARED - Bytecode format and parsing
│   ├── format.zig
│   ├── opcodes.zig
│   ├── string_table.zig
│   └── data_section.zig
├── executor/                    # SHARED - Dispatcher and handlers
│   ├── dispatcher.zig           # Generic Dispatcher(BackendType)
│   ├── dispatcher/
│   │   ├── handlers.zig
│   │   ├── resource.zig
│   │   ├── pass.zig
│   │   ├── queue.zig
│   │   └── frame.zig
│   ├── mock_gpu.zig             # Test backend
│   ├── wasm_gpu.zig             # Web backend (JS externs)
│   └── wgpu_native_gpu.zig      # NEW: Native backend (wgpu.h)
├── gpu/
│   ├── wgpu_c.zig               # NEW: @cImport of wgpu.h
│   └── context.zig              # NEW: Shared device/queue management
├── wasm.zig                     # Web entry point (WASM exports)
└── native_api.zig               # NEW: Native entry point (C exports)

native/                          # Platform-specific bindings
├── ios/
│   ├── PngineKit/               # Swift package
│   │   └── Sources/
│   │       ├── PngineView.swift
│   │       └── PngineAnimationView.swift
│   └── pngine-bridging-header.h
├── android/
│   ├── pngine-android/          # Kotlin/JNI bindings
│   │   └── src/main/
│   │       ├── kotlin/PngineView.kt
│   │       └── jni/pngine_jni.c
│   └── CMakeLists.txt
├── macos/
│   └── PngineKit/               # Same Swift package, different target
├── windows/
│   └── pngine.h                 # C API for .NET/C++ consumption
└── linux/
    └── pngine.h                 # C API for GTK/Qt consumption

vendor/
└── wgpu-native/
    ├── include/wgpu.h
    └── lib/
        ├── ios/libwgpu_native.a
        ├── android/libwgpu_native.so
        ├── macos/libwgpu_native.a
        ├── windows/wgpu_native.lib
        └── linux/libwgpu_native.a
```

---

## The Generic Backend Pattern

The existing `Dispatcher` is already designed for this:

```zig
// executor/dispatcher.zig (existing, unchanged)
pub fn Dispatcher(comptime BackendType: type) type {
    Backend(BackendType).validate();  // Compile-time interface check

    return struct {
        backend: *BackendType,
        module: *const Module,
        // ... dispatcher state

        pub fn step(self: *Self, allocator: Allocator) !void {
            // Decode opcode, dispatch to handler
            // Handler calls self.backend.createBuffer(), etc.
        }
    };
}
```

**Current backends:**
```zig
// MockGPU - records calls for testing
pub const MockDispatcher = Dispatcher(MockGPU);

// WasmGPU - calls JS via extern functions
pub const WasmDispatcher = Dispatcher(WasmGPU);
```

**New backend:**
```zig
// WgpuNativeGPU - calls wgpu.h C API
pub const NativeDispatcher = Dispatcher(WgpuNativeGPU);
```

---

## WgpuNativeGPU Backend

The new backend (~500 LOC) implements the same interface as WasmGPU but calls wgpu-native's C API:

```zig
//! src/executor/wgpu_native_gpu.zig
//!
//! Native GPU backend using wgpu-native C API.
//! Works on iOS (Metal), Android (Vulkan), macOS, Windows, Linux.

const std = @import("std");
const wgpu = @cImport({ @cInclude("wgpu.h"); });
const bytecode = @import("bytecode");
const Module = bytecode.format.Module;

pub const WgpuNativeGPU = struct {
    const Self = @This();

    // Shared context (one per app)
    ctx: *Context,

    // Per-animation resources
    surface: wgpu.WGPUSurface,
    buffers: [256]?wgpu.WGPUBuffer,
    textures: [128]?wgpu.WGPUTexture,
    shaders: [64]?wgpu.WGPUShaderModule,
    render_pipelines: [64]?wgpu.WGPURenderPipeline,
    compute_pipelines: [64]?wgpu.WGPUComputePipeline,
    bind_groups: [128]?wgpu.WGPUBindGroup,

    // Current encoder state
    encoder: ?wgpu.WGPUCommandEncoder,
    render_pass: ?wgpu.WGPURenderPassEncoder,
    compute_pass: ?wgpu.WGPUComputePassEncoder,

    // Bytecode module reference
    module: ?*const Module,

    // ========================================================================
    // Backend Interface (matches WasmGPU, MockGPU)
    // ========================================================================

    pub fn createBuffer(self: *Self, alloc: Allocator, id: u16, size: u32, usage: u8) !void {
        const buffer = wgpu.wgpuDeviceCreateBuffer(self.ctx.device, &.{
            .size = size,
            .usage = mapBufferUsage(usage),
            .mappedAtCreation = false,
        });
        self.buffers[id] = buffer;
    }

    pub fn createShaderModule(self: *Self, alloc: Allocator, id: u16, wgsl_id: u16) !void {
        const code = try self.resolveWgsl(alloc, wgsl_id);
        defer alloc.free(code);

        const desc = wgpu.WGPUShaderModuleWGSLDescriptor{
            .chain = .{ .sType = wgpu.WGPUSType_ShaderModuleWGSLDescriptor },
            .code = code.ptr,
        };

        self.shaders[id] = wgpu.wgpuDeviceCreateShaderModule(self.ctx.device, &.{
            .nextInChain = @ptrCast(&desc),
        });
    }

    pub fn beginRenderPass(self: *Self, alloc: Allocator, target: u16, load: u8, store: u8, depth: u16) !void {
        // Get surface texture or custom texture
        const view = if (target == 0)
            self.getSurfaceView()
        else
            self.getTextureView(target);

        self.encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.ctx.device, null);
        self.render_pass = wgpu.wgpuCommandEncoderBeginRenderPass(self.encoder, &.{
            .colorAttachmentCount = 1,
            .colorAttachments = &.{
                .view = view,
                .loadOp = @enumFromInt(load),
                .storeOp = @enumFromInt(store),
                .clearValue = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            },
        });
    }

    pub fn draw(self: *Self, alloc: Allocator, verts: u32, insts: u32, first_v: u32, first_i: u32) !void {
        wgpu.wgpuRenderPassEncoderDraw(self.render_pass, verts, insts, first_v, first_i);
    }

    pub fn endPass(self: *Self, alloc: Allocator) !void {
        if (self.render_pass) |rp| {
            wgpu.wgpuRenderPassEncoderEnd(rp);
            self.render_pass = null;
        }
        if (self.compute_pass) |cp| {
            wgpu.wgpuComputePassEncoderEnd(cp);
            self.compute_pass = null;
        }
    }

    pub fn submit(self: *Self, alloc: Allocator) !void {
        const cmd = wgpu.wgpuCommandEncoderFinish(self.encoder, null);
        wgpu.wgpuQueueSubmit(self.ctx.queue, 1, &cmd);
        wgpu.wgpuSurfacePresent(self.surface);
        self.encoder = null;
    }

    // ... remaining methods match WasmGPU interface
};

/// Shared GPU context (one instance per app)
pub const Context = struct {
    instance: wgpu.WGPUInstance,
    adapter: wgpu.WGPUAdapter,
    device: wgpu.WGPUDevice,
    queue: wgpu.WGPUQueue,

    pub fn init() !Context {
        const instance = wgpu.wgpuCreateInstance(null);
        // ... adapter and device creation
    }
};
```

**Key insight**: The method signatures match WasmGPU exactly. The Dispatcher doesn't care whether the backend calls JS externs or C functions.

---

## Platform Bindings

Each platform needs only:
1. **Surface creation** (from native window handle)
2. **C API wrapper** (thin layer for FFI)
3. **Platform UI component** (view/widget)

### Shared C API (native_api.zig → pngine.h)

```c
// include/pngine.h - shared across all native platforms
#ifndef PNGINE_H
#define PNGINE_H

#include <stdint.h>
#include <stddef.h>

typedef struct PngineContext PngineContext;
typedef struct PngineAnimation PngineAnimation;

// Global initialization (call once)
int pngine_init(void);
void pngine_shutdown(void);
void pngine_memory_warning(void);

// Animation lifecycle
PngineAnimation* pngine_create(const uint8_t* bytecode, size_t len, void* surface_handle);
void pngine_render(PngineAnimation* anim, float time);
void pngine_resize(PngineAnimation* anim, uint32_t width, uint32_t height);
void pngine_destroy(PngineAnimation* anim);

#endif
```

### iOS (Swift + CAMetalLayer)

```swift
// ~150 LOC
public class PngineAnimationView: UIView {
    private var metalLayer: CAMetalLayer!
    private var animation: OpaquePointer?
    private var displayLink: CADisplayLink?

    public func load(bytecode: Data) {
        bytecode.withUnsafeBytes { ptr in
            animation = pngine_create(
                ptr.baseAddress,
                ptr.count,
                Unmanaged.passUnretained(metalLayer).toOpaque()
            )
        }
    }

    @objc private func render(_ link: CADisplayLink) {
        pngine_render(animation, Float(link.timestamp - startTime))
    }
}
```

### Android (Kotlin + JNI + SurfaceView)

```kotlin
// ~100 LOC Kotlin
class PngineView(context: Context) : SurfaceView(context), SurfaceHolder.Callback {
    private var animationPtr: Long = 0
    private val choreographer = Choreographer.getInstance()

    fun load(bytecode: ByteArray) {
        animationPtr = nativeCreate(bytecode, holder.surface)
    }

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            nativeRender(animationPtr, (frameTimeNanos - startTime) / 1e9f)
            choreographer.postFrameCallback(this)
        }
    }

    // JNI bindings
    private external fun nativeCreate(bytecode: ByteArray, surface: Surface): Long
    private external fun nativeRender(ptr: Long, time: Float)
}
```

```c
// ~50 LOC JNI
JNIEXPORT jlong JNICALL Java_PngineView_nativeCreate(
    JNIEnv* env, jobject obj, jbyteArray bytecode, jobject surface
) {
    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    jbyte* bytes = (*env)->GetByteArrayElements(env, bytecode, NULL);
    jsize len = (*env)->GetArrayLength(env, bytecode);

    PngineAnimation* anim = pngine_create((uint8_t*)bytes, len, window);

    (*env)->ReleaseByteArrayElements(env, bytecode, bytes, 0);
    return (jlong)anim;
}
```

### Desktop (macOS/Windows/Linux)

Desktop uses the same C API with platform-specific window handles:
- **macOS**: NSView + CAMetalLayer (same as iOS)
- **Windows**: HWND
- **Linux**: X11 Window or Wayland surface

---

## wgpu-native Integration

wgpu-native is a Rust project that exposes WebGPU via a C API. Key points:

### Building wgpu-native

```bash
# Clone and build for each platform
git clone https://github.com/gfx-rs/wgpu-native
cd wgpu-native

# iOS
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
cargo build --release --target x86_64-apple-ios

# Android
cargo build --release --target aarch64-linux-android
cargo build --release --target armv7-linux-androideabi

# Desktop
cargo build --release  # Host platform
```

### Binary Sizes

| Platform | wgpu-native size | Notes |
|----------|------------------|-------|
| iOS arm64 | ~3.5 MB | Metal backend only |
| Android arm64 | ~4.2 MB | Vulkan backend |
| macOS arm64 | ~3.8 MB | Metal backend |
| Windows x64 | ~5.1 MB | DX12 + Vulkan |
| Linux x64 | ~4.5 MB | Vulkan + OpenGL |

### Linking in Zig

```zig
// build.zig
const lib = b.addStaticLibrary(.{
    .name = "pngine",
    .root_source_file = b.path("src/native_api.zig"),
    .target = target,
});

// Link wgpu-native
lib.addLibraryPath(b.path("vendor/wgpu-native/lib/" ++ target_name));
lib.linkSystemLibrary("wgpu_native");

// Platform frameworks
if (target.os_tag == .ios or target.os_tag == .macos) {
    lib.linkFramework("Metal");
    lib.linkFramework("QuartzCore");
}
```

---

## Build Matrix

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           BUILD TARGETS                                      │
├──────────────┬────────────────────┬────────────────────┬────────────────────┤
│ Platform     │ Zig Target         │ wgpu Backend       │ Output             │
├──────────────┼────────────────────┼────────────────────┼────────────────────┤
│ Web          │ wasm32-freestanding│ N/A (use JS)       │ pngine.wasm        │
│ iOS Device   │ aarch64-ios        │ Metal              │ libpngine.a        │
│ iOS Sim ARM  │ aarch64-ios-sim    │ Metal              │ libpngine.a        │
│ iOS Sim x64  │ x86_64-ios         │ Metal              │ libpngine.a        │
│ Android ARM  │ aarch64-android    │ Vulkan             │ libpngine.so       │
│ Android x86  │ x86_64-android     │ Vulkan             │ libpngine.so       │
│ macOS ARM    │ aarch64-macos      │ Metal              │ libpngine.dylib    │
│ macOS x64    │ x86_64-macos       │ Metal              │ libpngine.dylib    │
│ Windows x64  │ x86_64-windows     │ DX12/Vulkan        │ pngine.dll         │
│ Linux x64    │ x86_64-linux       │ Vulkan             │ libpngine.so       │
└──────────────┴────────────────────┴────────────────────┴────────────────────┘
```

---

## Comparison: Unified Zig vs Per-Platform Rewrites

| Aspect | Per-Platform (Rust iOS, etc.) | Unified Zig |
|--------|-------------------------------|-------------|
| **Bytecode implementations** | N (one per platform) | 1 |
| **Dispatcher implementations** | N | 1 |
| **Bug surface** | N × bugs | 1 × bugs |
| **Feature parity effort** | O(N × features) | O(features) |
| **Languages to know** | Zig + Rust + Swift + Kotlin | Zig + thin bindings |
| **Total new code** | ~2000 LOC × platforms | ~500 LOC shared + ~300 LOC × platforms |
| **Build complexity** | cargo + zig + gradle + xcode | zig + gradle + xcode |

---

## Migration Path

### Phase 1: WgpuNativeGPU Backend (Week 1-2)
- [ ] Add `src/executor/wgpu_native_gpu.zig`
- [ ] Add `src/gpu/wgpu_c.zig` with @cImport
- [ ] Add `src/gpu/context.zig` for shared device/queue
- [ ] Vendor wgpu-native headers
- [ ] Test on macOS first (easiest to debug)

### Phase 2: iOS Integration (Week 2-3)
- [ ] Add `src/native_api.zig` (C exports)
- [ ] Create `native/ios/PngineKit` Swift package
- [ ] Build XCFramework
- [ ] Test on iPhone simulator and device

### Phase 3: Android Integration (Week 3-4)
- [ ] Add JNI bindings in `native/android/`
- [ ] Create Kotlin PngineView
- [ ] Build AAR
- [ ] Test on Android emulator and device

### Phase 4: Desktop (Week 4+)
- [ ] macOS: Same Swift code, different target
- [ ] Windows: C API + example integration
- [ ] Linux: C API + GTK/Qt example

---

## Open Questions

### Q1: Async wgpu operations
wgpu-native uses async callbacks for adapter/device creation. Options:
1. Block in C API init (simpler, slight startup delay)
2. Expose async to platform layer (complex)

**Recommendation**: Block in init. 100-200ms at app launch is acceptable.

### Q2: Shader caching
wgpu-native has pipeline caching. Should we:
1. Let wgpu handle it (automatic)
2. Manage disk cache ourselves (more control)

**Recommendation**: Start with wgpu automatic caching. Add explicit caching if needed.

### Q3: Error handling across FFI
Zig errors don't cross C boundary easily. Options:
1. Return error codes + global error string
2. Return nullable + last_error() function
3. Panic on unrecoverable errors (simpler)

**Recommendation**: Option 2 for recoverable errors, panic for truly fatal.

---

## Summary

The unified Zig architecture means:

1. **One bytecode parser** - fixes in one place
2. **One dispatcher** - consistent execution everywhere
3. **One native GPU backend** - wgpu-native handles Metal/Vulkan/DX12
4. **Thin platform bindings** - just surface creation and lifecycle
5. **Future platforms for free** - WebGPU is the abstraction layer

This approach aligns with PNGine's goal of "shader art that runs everywhere" by making "everywhere" a build flag rather than a rewrite.
