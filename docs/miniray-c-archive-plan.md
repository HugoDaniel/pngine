# Miniray C-Archive Integration Plan

**Goal**: Eliminate subprocess spawning overhead by linking miniray as a C static
library directly into the pngine binary.

**Current State**: pngine spawns `miniray reflect` as subprocess via
`std.process.Child` (~50-100ms per invocation including process creation).

**Target State**: Direct function call via C FFI (~1-5ms per invocation).

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  pngine (Zig)                                                   │
│                                                                 │
│  ┌─────────────────┐     ┌──────────────────────────────────┐  │
│  │ src/reflect/    │     │ libminiray.a (Go → C archive)    │  │
│  │ miniray.zig     │────▶│                                  │  │
│  │                 │     │ miniray_reflect(src, len) → json │  │
│  │ (Zig @cImport)  │     │ miniray_free(ptr)                │  │
│  └─────────────────┘     └──────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Go C-Archive Library (miniray side)

### 1.1 Create `cmd/miniray-lib/main.go`

```go
package main

/*
#include <stdlib.h>
#include <string.h>
*/
import "C"
import (
    "encoding/json"
    "unsafe"

    "github.com/HugoDaniel/miniray/internal/reflect"
)

// MinirayResult is the C-compatible result structure
type MinirayResult struct {
    json_ptr *C.char  // JSON string (caller must free)
    json_len C.int    // Length of JSON string
    error    C.int    // 0 = success, non-zero = error code
}

//export miniray_reflect
func miniray_reflect(source *C.char, source_len C.int, out_json **C.char, out_len *C.int) C.int {
    // Convert C string to Go string (no copy needed with unsafe)
    goSource := C.GoStringN(source, source_len)

    // Run reflection
    result := reflect.Reflect(goSource)

    // Serialize to JSON
    jsonBytes, err := json.Marshal(result)
    if err != nil {
        return 1 // JSON encoding error
    }

    // Allocate C memory for result (caller must free with miniray_free)
    *out_json = C.CString(string(jsonBytes))
    *out_len = C.int(len(jsonBytes))

    return 0 // Success
}

//export miniray_free
func miniray_free(ptr *C.char) {
    C.free(unsafe.Pointer(ptr))
}

// Required for c-archive build mode
func main() {}
```

### 1.2 Build Script for C-Archive

Create `miniray/scripts/build-carchive.sh`:

```bash
#!/bin/bash
set -e

# Output directory
OUT_DIR="${1:-build}"
mkdir -p "$OUT_DIR"

# Build for current platform
echo "Building libminiray.a for $(go env GOOS)/$(go env GOARCH)..."
CGO_ENABLED=1 go build \
    -buildmode=c-archive \
    -o "$OUT_DIR/libminiray.a" \
    ./cmd/miniray-lib

echo "Generated:"
echo "  $OUT_DIR/libminiray.a  (static library)"
echo "  $OUT_DIR/libminiray.h  (C header)"
```

### 1.3 Cross-Compilation Targets

For pngine's npm package (6 platforms), add to `scripts/build-carchive.sh`:

```bash
# Cross-compile for all targets
TARGETS=(
    "darwin/arm64"
    "darwin/amd64"
    "linux/amd64"
    "linux/arm64"
    "windows/amd64"
    "windows/arm64"
)

for target in "${TARGETS[@]}"; do
    IFS='/' read -r os arch <<< "$target"
    echo "Building for $os/$arch..."

    CGO_ENABLED=1 GOOS=$os GOARCH=$arch \
        go build -buildmode=c-archive \
        -o "$OUT_DIR/libminiray-$os-$arch.a" \
        ./cmd/miniray-lib
done
```

**Note**: Cross-compiling Go with cgo requires C cross-compilers (clang for
macOS, gcc-aarch64-linux-gnu, etc.). For simplicity, initially build only for
native platform.

---

## Phase 2: Zig Integration (pngine side)

### 2.1 Modify `build.zig`

Add libminiray linking:

```zig
// In build.zig, after creating the lib_module and exe:

// Miniray C library integration
const miniray_lib_path = b.option(
    []const u8,
    "miniray-lib",
    "Path to libminiray.a (Go C-archive)",
) orelse blk: {
    // Default: look in ../miniray/build/
    const default_path = "../miniray/build/libminiray.a";
    if (std.fs.cwd().access(default_path, .{})) |_| {
        break :blk default_path;
    } else |_| {
        break :blk null;
    }
};

// Only link if library exists
if (miniray_lib_path) |lib_path| {
    // Link the static library
    exe.addObjectFile(.{ .cwd_relative = lib_path });

    // Link required system libraries (Go runtime dependencies)
    if (target.result.os.tag == .macos) {
        exe.linkFramework("CoreFoundation");
        exe.linkFramework("Security");
    }
    exe.linkSystemLibrary("pthread");
    exe.linkLibC();

    // Define compile-time flag
    const options = b.addOptions();
    options.addOption(bool, "has_miniray_lib", true);
    lib_module.addOptions("build_options", options);
} else {
    const options = b.addOptions();
    options.addOption(bool, "has_miniray_lib", false);
    lib_module.addOptions("build_options", options);
}
```

### 2.2 Create `src/reflect/miniray_ffi.zig`

C FFI bindings:

```zig
//! Miniray FFI Bindings
//!
//! Direct C function calls to libminiray.a for WGSL reflection.
//! Falls back to subprocess spawning if library not linked.

const std = @import("std");
const build_options = @import("build_options");

/// C bindings from libminiray.h
const c = @cImport({
    @cInclude("libminiray.h");
});

pub const has_miniray_lib = build_options.has_miniray_lib;

/// Reflect on WGSL source using the linked C library.
/// Returns JSON string allocated with C malloc (must free with freeJson).
/// Only available when has_miniray_lib is true.
pub fn reflectFfi(source: []const u8) ![]const u8 {
    if (!has_miniray_lib) {
        @compileError("miniray_ffi.reflectFfi called but has_miniray_lib is false");
    }

    var out_json: [*c]u8 = undefined;
    var out_len: c_int = 0;

    const result = c.miniray_reflect(
        source.ptr,
        @intCast(source.len),
        &out_json,
        &out_len,
    );

    if (result != 0) {
        return error.MinirayReflectFailed;
    }

    // Return slice pointing to C-allocated memory
    return out_json[0..@intCast(out_len)];
}

/// Free JSON string allocated by reflectFfi.
pub fn freeJson(json_ptr: []const u8) void {
    if (!has_miniray_lib) {
        @compileError("miniray_ffi.freeJson called but has_miniray_lib is false");
    }
    c.miniray_free(@ptrCast(@constCast(json_ptr.ptr)));
}
```

### 2.3 Modify `src/reflect/miniray.zig`

Update to use FFI when available:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

// Conditional FFI import
const miniray_ffi = @import("miniray_ffi.zig");

// ... existing type definitions (Field, Layout, Binding, etc.) ...

pub const Miniray = struct {
    miniray_path: ?[]const u8 = null,

    pub const Error = error{
        OutOfMemory,
        SpawnFailed,
        MinirayNotFound,
        ProcessFailed,
        InvalidJson,
        Timeout,
    };

    pub fn reflect(self: *const Miniray, gpa: Allocator, wgsl_source: []const u8) Error!ReflectionData {
        std.debug.assert(wgsl_source.len > 0);

        // Use FFI if available (compile-time check)
        if (comptime miniray_ffi.has_miniray_lib) {
            return self.reflectViaFfi(gpa, wgsl_source);
        } else {
            return self.reflectViaSubprocess(gpa, wgsl_source);
        }
    }

    /// Fast path: direct C function call
    fn reflectViaFfi(self: *const Miniray, gpa: Allocator, wgsl_source: []const u8) Error!ReflectionData {
        _ = self; // unused in FFI path

        const json_data = miniray_ffi.reflectFfi(wgsl_source) catch {
            return error.ProcessFailed;
        };
        defer miniray_ffi.freeJson(json_data);

        return parseJson(gpa, json_data);
    }

    /// Fallback path: subprocess spawning (existing implementation)
    fn reflectViaSubprocess(self: *const Miniray, gpa: Allocator, wgsl_source: []const u8) Error!ReflectionData {
        // ... existing subprocess code from lines 217-262 ...
    }

    // ... rest of existing implementation ...
};
```

---

## Phase 3: Build System Integration

### 3.1 Makefile Target (miniray)

Add to `miniray/Makefile`:

```makefile
.PHONY: lib
lib:
	@mkdir -p build
	CGO_ENABLED=1 go build -buildmode=c-archive \
		-o build/libminiray.a ./cmd/miniray-lib
	@echo "Built build/libminiray.a"

.PHONY: lib-all
lib-all:
	./scripts/build-carchive.sh build
```

### 3.2 Integration Test

Add to pngine's test suite to verify FFI works:

```zig
test "Miniray FFI: basic reflection" {
    if (!comptime miniray_ffi.has_miniray_lib) {
        // Skip test if library not linked
        return error.SkipZigTest;
    }

    const wgsl =
        \\struct U { time: f32, }
        \\@group(0) @binding(0) var<uniform> u: U;
    ;

    const json_data = try miniray_ffi.reflectFfi(wgsl);
    defer miniray_ffi.freeJson(json_data);

    // Verify it's valid JSON
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json_data,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
}
```

---

## Phase 4: Development Workflow

### 4.1 First-Time Setup

```bash
# 1. Build miniray library
cd /Users/hugo/Development/miniray
make lib

# 2. Build pngine with library
cd /Users/hugo/Development/pngine/compute-initialization
/Users/hugo/.zvm/bin/zig build -Dminiray-lib=../miniray/build/libminiray.a

# 3. Run tests to verify
/Users/hugo/.zvm/bin/zig build test-standalone --summary all
```

### 4.2 Continuous Development

After modifying miniray reflection code:

```bash
# Rebuild library
cd ../miniray && make lib && cd -

# Rebuild pngine
/Users/hugo/.zvm/bin/zig build
```

### 4.3 CI/CD Integration

```yaml
# .github/workflows/build.yml
jobs:
  build:
    steps:
      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'

      - name: Build miniray library
        run: |
          cd miniray
          CGO_ENABLED=1 go build -buildmode=c-archive \
            -o build/libminiray.a ./cmd/miniray-lib

      - name: Build pngine
        run: |
          cd pngine
          zig build -Dminiray-lib=../miniray/build/libminiray.a
```

---

## Binary Size Impact

| Component | Approximate Size |
|-----------|------------------|
| Go runtime | ~2-3 MB |
| miniray reflection code | ~500 KB |
| **Total added to pngine** | **~3 MB** |

Current pngine CLI is ~1 MB, so total would be ~4 MB. This is acceptable for a
CLI tool.

---

## Fallback Behavior

The implementation gracefully falls back to subprocess spawning when:

1. `libminiray.a` is not found during build
2. `-Dminiray-lib` option not provided
3. Cross-compiling without matching library

This ensures:
- Development without Go toolchain still works
- npm package doesn't require Go at runtime
- Tests can run in either mode

---

## Implementation Order

1. **Day 1**: Create `cmd/miniray-lib/main.go` with `miniray_reflect` export
2. **Day 1**: Add `make lib` target to miniray
3. **Day 2**: Create `src/reflect/miniray_ffi.zig` with C bindings
4. **Day 2**: Modify `build.zig` to optionally link library
5. **Day 2**: Update `src/reflect/miniray.zig` to use FFI path
6. **Day 3**: Test and benchmark both paths
7. **Day 3**: Update CI/documentation

---

## Future: Zig Rewrite

This C-archive approach is a stepping stone. The long-term plan is to rewrite
the WGSL reflection in pure Zig, which would:

- Eliminate Go runtime overhead (~3 MB savings)
- Remove cgo cross-compilation complexity
- Enable comptime reflection for even faster builds
- Share code with existing DSL lexer/parser

The FFI interface designed here (JSON in/out) makes the transition seamless—just
swap the implementation without changing the caller.
