# PNGine Native Platform Bindings

Native platform bindings for PNGine using a unified Zig core with wgpu-native.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SHARED ZIG CORE                                    │
│                                                                              │
│  src/executor/wgpu_native_gpu.zig  - WgpuNativeGPU backend                  │
│  src/gpu/wgpu_c.zig                - wgpu.h C API bindings                  │
│  src/native_api.zig                - C exports (pngine_init, etc.)          │
│                                                                              │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
                    ▼               ▼               ▼
              ┌───────────┐   ┌───────────┐   ┌───────────┐
              │   iOS     │   │  Android  │   │  Desktop  │
              │  (Swift)  │   │ (Kotlin)  │   │    (C)    │
              └───────────┘   └───────────┘   └───────────┘
```

## Quick Start

### 1. Download wgpu-native Libraries

```bash
# Download for all platforms
./scripts/download-wgpu-native.sh

# Or download specific platform
./scripts/download-wgpu-native.sh ios
./scripts/download-wgpu-native.sh macos
```

### 2. Build

```bash
# Build macOS dynamic library (for development)
/Users/hugo/.zvm/bin/zig build native

# Build iOS static libraries
/Users/hugo/.zvm/bin/zig build native-ios

# Create XCFramework for iOS distribution
./scripts/build-xcframework.sh
```

## Directory Structure

```
native/
├── include/
│   └── pngine.h              # C API header (shared across all platforms)
├── ios/
│   └── PngineKit/            # Swift package
│       ├── Package.swift
│       └── Sources/
│           └── PngineKit/
│               ├── PngineKit.swift      # C function declarations
│               └── PngineView.swift     # SwiftUI/UIKit views
├── android/
│   └── pngine-android/       # Android library
│       └── src/main/
│           ├── kotlin/
│           │   └── com/pngine/
│           │       └── PngineView.kt    # Kotlin SurfaceView
│           └── jni/
│               └── pngine_jni.c         # JNI bridge
├── macos/                    # Uses same Swift package as iOS
├── windows/                  # C API wrapper (future)
├── linux/                    # C API wrapper (future)
├── build/                    # Build output (generated)
│   └── PngineCore.xcframework
└── README.md
```

## Usage

### iOS (SwiftUI)

```swift
import PngineKit

struct ContentView: View {
    let bytecode: Data  // PNGB bytecode

    var body: some View {
        PngineView(bytecode: bytecode)
            .frame(width: 300, height: 300)
    }
}
```

### iOS (UIKit)

```swift
import PngineKit

let animationView = PngineAnimationView()
animationView.load(bytecode: bytecodeData)
animationView.play()
```

### Android (Kotlin)

```kotlin
import com.pngine.PngineView

val pngineView = PngineView(context)
pngineView.load(bytecodeData)
pngineView.play()
```

### C/C++ (Desktop)

```c
#include "pngine.h"

// Initialize once
pngine_init();

// Create animation with platform window handle
PngineAnimation* anim = pngine_create(
    bytecode, bytecode_len,
    window_handle,  // HWND, NSView*, X11 Window, etc.
    width, height
);

// Render loop
while (running) {
    pngine_render(anim, elapsed_time);
}

// Cleanup
pngine_destroy(anim);
pngine_shutdown();
```

## C API Reference

```c
// Initialization
int pngine_init(void);              // Returns 0 on success
void pngine_shutdown(void);
bool pngine_is_initialized(void);
void pngine_memory_warning(void);

// Animation lifecycle
PngineAnimation* pngine_create(
    const uint8_t* bytecode,
    size_t bytecode_len,
    void* surface_handle,
    uint32_t width,
    uint32_t height
);

void pngine_render(PngineAnimation* anim, float time);
void pngine_resize(PngineAnimation* anim, uint32_t width, uint32_t height);
void pngine_destroy(PngineAnimation* anim);

// Utilities
const char* pngine_get_error(void);
uint32_t pngine_get_width(PngineAnimation* anim);
uint32_t pngine_get_height(PngineAnimation* anim);
const char* pngine_version(void);
```

## Platform-Specific Notes

### iOS / macOS

- Surface handle is `CAMetalLayer*`
- Uses Metal backend via wgpu-native
- Supports both UIKit and SwiftUI

### Android

- Surface handle is `ANativeWindow*` (from `Surface` via JNI)
- Uses Vulkan backend via wgpu-native
- Supports API level 24+

### Windows

- Surface handle is `HWND`
- Uses DX12 or Vulkan backend

### Linux

- Surface handle is X11 `Window` or Wayland `wl_surface*`
- Uses Vulkan backend

## Memory Budget

| Component          | Size    |
|--------------------|---------|
| Shared context     | ~10 MB  |
| Per animation      | <1 KB   |
| 10 animations      | ~10 MB total |

## Build Output

| Target | Output Location | Size |
|--------|-----------------|------|
| macOS | `zig-out/lib/libpngine.dylib` | ~1 MB |
| iOS (device) | `zig-out/lib/aarch64-ios/libpngine.a` | ~1 MB |
| iOS (sim arm64) | `zig-out/lib/aarch64-ios-simulator/libpngine.a` | ~1 MB |
| iOS (sim x64) | `zig-out/lib/x86_64-ios-simulator/libpngine.a` | ~1 MB |
| XCFramework | `native/build/PngineCore.xcframework` | ~10 MB |

## Status

### Infrastructure (Complete)
- [x] C API design (`pngine.h`)
- [x] iOS Swift bindings (`native/ios/PngineKit/`)
- [x] iOS build targets in build.zig (`zig build native-ios`)
- [x] macOS build targets in build.zig (`zig build native`)
- [x] XCFramework build script (`scripts/build-xcframework.sh`)
- [x] Download script for wgpu-native (`scripts/download-wgpu-native.sh`)
- [x] wgpu-native v27.0.4.0 libraries downloaded

### Backend (Incomplete)
- [ ] Update wgpu_c.zig for wgpu-native v27 callback API
- [ ] Complete WgpuNativeGPU adapter/device initialization
- [ ] Complete pipeline descriptor parsing
- [ ] Complete bind group creation
- [ ] Complete render/compute pass operations

### Future Platforms
- [ ] Android Kotlin bindings
- [ ] Windows bindings
- [ ] Linux bindings
- [ ] Integration tests

## Build Requirements

### For iOS builds:
- **Xcode with iOS SDK** (not just Command Line Tools)
- Run: `xcrun --sdk iphoneos --show-sdk-path` to verify
- Command Line Tools alone will NOT work for iOS cross-compilation

## Related Documentation

- [iOS Viewer Plan](../docs/ios-viewer-zig-plan.md)
- [Multiplatform Zig Architecture](../docs/multiplatform-zig-architecture.md)
