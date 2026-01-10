# PNGine iOS Viewer - Pure Zig Architecture

**Status**: In Progress (Infrastructure Complete, Backend Incomplete)
**Key Insight**: Reuse existing Zig dispatcher with wgpu-native C API backend

## Implementation Status

| Component | Status | Location |
|-----------|--------|----------|
| C API Header | ✅ Complete | `native/include/pngine.h` |
| C API Implementation | 🟡 Partial | `src/native_api.zig` |
| wgpu C Bindings | ❌ Needs Update | `src/gpu/wgpu_c.zig` (v27 API changes) |
| WgpuNativeGPU Backend | 🔴 Stubs Only | `src/executor/wgpu_native_gpu.zig` |
| Swift Package | ✅ Complete | `native/ios/PngineKit/` |
| iOS Build Target | ✅ Complete | `build.zig` (`native-ios` step) |
| macOS Build Target | ✅ Complete | `build.zig` (`native` step) |
| wgpu-native Download | ✅ Complete | `scripts/download-wgpu-native.sh` |
| wgpu-native iOS libs | ✅ Downloaded | `vendor/wgpu-native/ios/` |
| XCFramework Script | ✅ Complete | `scripts/build-xcframework.sh` |

## Build Requirements

### Prerequisites

1. **Zig 0.16+** - Required for cross-compilation
2. **Xcode with iOS SDK** - Required for iOS builds (not just Command Line Tools)
   - `xcrun --sdk iphoneos --show-sdk-path` must work
3. **wgpu-native libraries** - Run `./scripts/download-wgpu-native.sh`

### Known Issues

1. **wgpu-native v27 API Changes**: The C bindings in `wgpu_c.zig` need updates for the new callback-based API:
   - `wgpuInstanceRequestAdapter` now takes `WGPURequestAdapterCallbackInfo` instead of separate callback + userdata
   - `wgpuAdapterRequestDevice` similarly changed

2. **WgpuNativeGPU Incomplete**: Many functions are stubs that need implementation:
   - `createRenderPipeline`, `createComputePipeline`
   - `createBindGroup`, `createBindGroupLayout`, `createPipelineLayout`
   - All render/compute pass operations

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Swift Layer (native/ios/PngineKit/)                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  PngineView.swift - SwiftUI + UIKit views                               ││
│  │  PngineKit.swift  - C function declarations (@_silgen_name)             ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ C API (native/include/pngine.h)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Zig Layer                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  src/native_api.zig (C exports)                                         ││
│  │  - pngine_init()    → Context.init()                                    ││
│  │  - pngine_create()  → parse bytecode, create WgpuNativeGPU              ││
│  │  - pngine_render()  → dispatcher.executeFrame()                         ││
│  │  - pngine_destroy() → cleanup resources                                 ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  src/executor/dispatcher.zig (SHARED - unchanged)                       ││
│  │  - Generic Dispatcher(BackendType) over GPU backends                    ││
│  │  - Parses bytecode opcodes, dispatches to backend                       ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  src/executor/wgpu_native_gpu.zig                                       ││
│  │  - WgpuNativeGPU: implements Backend interface                          ││
│  │  - Context: shared wgpu instance/adapter/device/queue                   ││
│  │  - Calls wgpu.h C API via src/gpu/wgpu_c.zig                            ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ src/gpu/wgpu_c.zig (@cImport)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  wgpu-native (vendor/wgpu-native/)                                          │
│  - libwgpu_native.a (static library)                                        │
│  - WGSL → Metal transpilation via naga                                      │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Metal (GPU)                                                                │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Code Reuse

| Component | Web (WASM) | iOS (Native) | Shared? |
|-----------|------------|--------------|---------|
| Bytecode parser | `bytecode/format.zig` | Same | ✅ 100% |
| Dispatcher | `executor/dispatcher.zig` | Same | ✅ 100% |
| GPU Backend | `executor/wasm_gpu.zig` | `executor/wgpu_native_gpu.zig` | ❌ Different |
| API layer | `wasm.zig` | `native_api.zig` | ❌ Different |

**Result**: ~90% code reuse for core logic.

## Directory Structure

```
pngine/
├── src/
│   ├── native_api.zig              # C API exports (pngine_init, etc.)
│   ├── gpu/
│   │   └── wgpu_c.zig              # wgpu.h C bindings via @cImport
│   └── executor/
│       ├── dispatcher.zig          # Shared dispatcher (generic)
│       └── wgpu_native_gpu.zig     # Native GPU backend
├── native/
│   ├── include/
│   │   └── pngine.h                # Public C header
│   ├── ios/
│   │   └── PngineKit/              # Swift package
│   │       ├── Package.swift
│   │       └── Sources/PngineKit/
│   │           ├── PngineKit.swift     # C function declarations
│   │           └── PngineView.swift    # SwiftUI/UIKit views
│   ├── android/                    # Future
│   ├── macos/                      # Uses same Swift package
│   └── README.md
├── vendor/
│   └── wgpu-native/
│       ├── include/
│       │   ├── webgpu.h
│       │   └── wgpu.h
│       ├── lib/                    # macOS libraries
│       │   ├── libwgpu_native.a
│       │   └── libwgpu_native.dylib
│       └── ios/                    # iOS libraries (TO ADD)
│           ├── device/
│           │   └── libwgpu_native.a
│           └── simulator/
│               └── libwgpu_native.a
└── scripts/
    └── build-xcframework.sh        # TO ADD
```

## Remaining Work

### 1. Download iOS wgpu-native Libraries

```bash
# From https://github.com/gfx-rs/wgpu-native/releases

# iOS device (arm64)
curl -L https://github.com/gfx-rs/wgpu-native/releases/download/v24.0.0.2/wgpu-ios-aarch64-release.zip \
  -o wgpu-ios-device.zip
unzip wgpu-ios-device.zip -d vendor/wgpu-native/ios/device/

# iOS simulator (arm64)
curl -L https://github.com/gfx-rs/wgpu-native/releases/download/v24.0.0.2/wgpu-ios-aarch64-sim-release.zip \
  -o wgpu-ios-sim.zip
unzip wgpu-ios-sim.zip -d vendor/wgpu-native/ios/simulator/
```

### 2. Add iOS Build Target to build.zig

```zig
// iOS static library targets
const ios_step = b.step("native-ios", "Build iOS static library");

const ios_targets = [_]std.Target.Query{
    .{ .cpu_arch = .aarch64, .os_tag = .ios },                        // Device
    .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .simulator },     // Simulator ARM
    .{ .cpu_arch = .x86_64, .os_tag = .ios, .abi = .simulator },      // Simulator x64
};

for (ios_targets) |target_query| {
    const target = b.resolveTargetQuery(target_query);

    const lib = b.addStaticLibrary(.{
        .name = "pngine",
        .root_source_file = b.path("src/native_api.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    // Link wgpu-native
    lib.addIncludePath(b.path("vendor/wgpu-native/include"));
    // Library path depends on target...

    ios_step.dependOn(&lib.step);
}
```

### 3. Complete WgpuNativeGPU Implementation

Missing in `src/executor/wgpu_native_gpu.zig`:

- `createRenderPipeline()` - needs descriptor parsing
- `createComputePipeline()` - needs descriptor parsing
- `createBindGroup()` - needs entry parsing
- `createBindGroupLayout()` - needs descriptor parsing
- `createPipelineLayout()` - needs descriptor parsing

These require parsing binary descriptors from the bytecode data section.

### 4. Create XCFramework Build Script

```bash
#!/bin/bash
# scripts/build-xcframework.sh

set -e

ZIG=/Users/hugo/.zvm/bin/zig

# Build for all iOS targets
$ZIG build native-ios

# Create XCFramework
xcodebuild -create-xcframework \
    -library zig-out/lib/aarch64-ios/libpngine.a \
    -headers native/include/ \
    -library zig-out/lib/aarch64-ios-simulator/libpngine.a \
    -headers native/include/ \
    -output native/build/PngineCore.xcframework

echo "Created native/build/PngineCore.xcframework"
```

## Building

### Prerequisites

1. Zig 0.14+ (at `/Users/hugo/.zvm/bin/zig`)
2. wgpu-native libraries in `vendor/wgpu-native/`
3. Xcode Command Line Tools

### Commands

```bash
# Build macOS dynamic library (for development)
/Users/hugo/.zvm/bin/zig build native

# Build iOS static libraries
/Users/hugo/.zvm/bin/zig build native-ios

# Create XCFramework for distribution
./scripts/build-xcframework.sh

# Output: native/build/PngineCore.xcframework
```

## Usage

### Swift (iOS/macOS)

```swift
import PngineKit

// SwiftUI
struct ContentView: View {
    let bytecode: Data

    var body: some View {
        PngineView(bytecode: bytecode)
            .frame(width: 300, height: 300)
    }
}

// UIKit
let view = PngineAnimationView()
view.load(bytecode: bytecodeData)
view.play()
```

### Integration Steps

1. Add `PngineCore.xcframework` to your Xcode project
2. Add `PngineKit` Swift package (from `native/ios/PngineKit/`)
3. Import and use `PngineView` or `PngineAnimationView`

## Performance Budget

| Metric | Target | Current |
|--------|--------|---------|
| Binary size (iOS) | < 5 MB | TBD |
| Context init | < 200 ms | TBD |
| Animation create | < 10 ms | TBD |
| Frame render | < 2 ms | TBD |
| Memory per animation | < 1 KB | ✅ |

## Related Files

- `native/README.md` - Native platform overview
- `src/executor/wasm_gpu.zig` - Reference WASM backend
- `npm/pngine/src/gpu.js` - Reference JS CommandDispatcher
