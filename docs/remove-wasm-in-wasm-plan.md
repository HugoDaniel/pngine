# Remove WASM-in-WASM Plan

## Overview

Remove the nested WASM execution system from pngine. This system allows embedding
external `.wasm` files in the payload and calling their exported functions at
runtime. It was never fully implemented (JS runtime has only stubs) and is
superseded by the compute-first approach in `data-generation-plan.md`.

**Goal**: Remove ~800 lines of dead/incomplete code, simplify architecture.

**Non-Goal**: This plan does NOT remove the data generation opcodes (0x50-0x55)
which are separate, working, and useful for simple runtime data.

---

## Current Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        WASM-in-WASM Flow                                │
│                                                                         │
│  .pngine source                                                         │
│       │                                                                 │
│       ▼                                                                 │
│  #wasmCall macro ──► Analyzer ──► Emitter/wasm.zig                      │
│       │                               │                                 │
│       │                               ▼                                 │
│       │                    Reads external .wasm file                    │
│       │                               │                                 │
│       ▼                               ▼                                 │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                     .pngb Payload                               │    │
│  │  ┌──────────────────┐  ┌──────────────────────────────────────┐ │    │
│  │  │ Bytecode Section │  │ Data Section                         │ │    │
│  │  │                  │  │                                      │ │    │
│  │  │ init_wasm_module │  │ [embedded .wasm bytes - up to 4MB]   │ │    │
│  │  │ call_wasm_func   │  │                                      │ │    │
│  │  │ write_buffer_... │  │                                      │ │    │
│  │  └──────────────────┘  └──────────────────────────────────────┘ │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                              │                                          │
│                              ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                   Executor (dispatcher.zig)                     │    │
│  │                              │                                  │    │
│  │                              ▼                                  │    │
│  │                   wasm_gpu.zig extern stubs                     │    │
│  │                              │                                  │    │
│  │                              ▼                                  │    │
│  │                   gpu.js (TODO stubs - NOT IMPLEMENTED)         │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Files to Modify

### Phase 1: Remove DSL Support

| File | Action | Changes |
|------|--------|---------|
| `src/dsl/Token.zig` | Modify | Remove `macro_wasm_call` tag, remove from `macro_keywords` |
| `src/dsl/Ast.zig` | Modify | Remove `macro_wasm_call` node tag |
| `src/dsl/Parser.zig` | Modify | Remove `macro_wasm_call` case in `parseMacro()` |
| `src/dsl/Analyzer.zig` | Modify | Remove `wasm_call` symbol table, remove from `symbol_type_map` |
| `src/dsl/Emitter.zig` | Modify | Remove `wasm` import, remove `emitWasmCalls()` call |
| `src/dsl/emitter/wasm.zig` | **DELETE** | Entire file (387 lines) |

### Phase 2: Remove Bytecode Support

| File | Action | Changes |
|------|--------|---------|
| `src/bytecode/opcodes.zig` | Modify | Remove opcodes 0x26-0x28, `WasmArgType`, `WasmReturnType` |

### Phase 3: Remove Executor Support

| File | Action | Changes |
|------|--------|---------|
| `src/executor/dispatcher.zig` | Modify | Remove opcode handlers for 0x26-0x28 |
| `src/executor/wasm_gpu.zig` | Modify | Remove `initWasmModule`, `callWasmFunc`, `writeBufferFromWasm`, externs |
| `src/executor/mock_gpu.zig` | Modify | Remove WASM mock implementations |

### Phase 4: Remove JS Runtime Support

| File | Action | Changes |
|------|--------|---------|
| `npm/pngine/src/gpu.js` | Modify | Remove `INIT_WASM_MODULE`, `CALL_WASM_FUNC` commands, stub methods |

### Phase 5: Remove/Migrate Examples

| File | Action | Notes |
|------|--------|-------|
| `examples/wasm_rotated_cube.pngine` | **DELETE** or migrate | Uses `#wasmCall` for MVP matrix |
| `examples/data_wasm_cube.pngine` | **DELETE** or migrate | Uses `#wasmCall` for MVP matrix |
| `examples/assets/mvp.wasm` | **DELETE** | External WASM module |

---

## Detailed Changes

### 1. Token.zig

**Location**: `src/dsl/Token.zig`

```zig
// REMOVE from Tag enum (~line 70):
macro_wasm_call,

// REMOVE from macro_keywords StaticStringMap (~line 144):
.{ "wasmCall", .macro_wasm_call },
.{ "wasmCalls", .macro_wasm_call },
```

### 2. Ast.zig

**Location**: `src/dsl/Ast.zig`

```zig
// REMOVE from Node.Tag enum (~line 151):
macro_wasm_call,
```

### 3. Parser.zig

**Location**: `src/dsl/Parser.zig`

```zig
// REMOVE case in parseMacro() switch:
.macro_wasm_call => {
    // ... parsing logic ...
},
```

### 4. Analyzer.zig

**Location**: `src/dsl/Analyzer.zig`

```zig
// REMOVE from Analysis.symbols struct (~line 137):
wasm_call: std.StringHashMapUnmanaged(SymbolInfo),

// REMOVE from SymbolType enum (~line 216):
wasm_call,

// REMOVE from symbol_type_map (~line 255):
.{ "wasmCall", .wasm_call },
.{ "wasmCalls", .wasm_call },

// REMOVE case in getSymbolType() (~line 280):
.macro_wasm_call => .wasm_call,

// REMOVE from deinit():
self.symbols.wasm_call.deinit(self.gpa);

// REMOVE from reset():
self.symbols.wasm_call.clearRetainingCapacity();
```

### 5. Emitter.zig

**Location**: `src/dsl/Emitter.zig`

```zig
// REMOVE import:
const wasm = @import("emitter/wasm.zig");

// REMOVE call in emit() or emitFrame():
try wasm.emitWasmCalls(self);

// REMOVE any wasm-related helper calls
```

### 6. emitter/wasm.zig

**Location**: `src/dsl/emitter/wasm.zig`

**Action**: DELETE ENTIRE FILE (387 lines)

### 7. opcodes.zig

**Location**: `src/bytecode/opcodes.zig`

```zig
// REMOVE opcodes (lines 166-191):
init_wasm_module = 0x26,
call_wasm_func = 0x27,
write_buffer_from_wasm = 0x28,

// REMOVE WasmArgType enum (lines 372-403):
pub const WasmArgType = enum(u8) {
    literal_f32 = 0x00,
    canvas_width = 0x01,
    canvas_height = 0x02,
    time_total = 0x03,
    literal_i32 = 0x04,
    literal_u32 = 0x05,
    time_delta = 0x06,

    pub fn valueByteSize(self: WasmArgType) u8 { ... }
};

// REMOVE WasmReturnType struct (lines 405-423):
pub const WasmReturnType = struct {
    pub fn byteSize(type_name: []const u8) ?u32 { ... }
};
```

### 8. dispatcher.zig

**Location**: `src/executor/dispatcher.zig`

```zig
// REMOVE opcode handlers (lines 848-895):
.init_wasm_module => {
    const module_id = try self.readVarint();
    const wasm_data_id = try self.readVarint();
    try self.backend.initWasmModule(allocator, @intCast(module_id), @intCast(wasm_data_id));
},

.call_wasm_func => {
    // ... ~30 lines ...
},

.write_buffer_from_wasm => {
    const call_id = try self.readVarint();
    const buffer_id = try self.readVarint();
    const offset = try self.readVarint();
    const byte_len = try self.readVarint();
    try self.backend.writeBufferFromWasm(allocator, @intCast(call_id), @intCast(buffer_id), offset, byte_len);
},
```

### 9. wasm_gpu.zig

**Location**: `src/executor/wasm_gpu.zig`

```zig
// REMOVE extern declarations (lines 61-63):
extern "env" fn gpuInitWasmModule(module_id: u16, data_ptr: [*]const u8, data_len: u32) void;
extern "env" fn gpuCallWasmFunc(call_id: u16, module_id: u16, func_name_ptr: [*]const u8, func_name_len: u32, args_ptr: [*]const u8, args_len: u32) void;
extern "env" fn gpuWriteBufferFromWasm(call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) void;

// REMOVE methods (lines 459-486):
pub fn initWasmModule(self: *Self, allocator: Allocator, module_id: u16, wasm_data_id: u16) !void { ... }
pub fn callWasmFunc(self: *Self, allocator: Allocator, call_id: u16, module_id: u16, func_name_id: u16, args: []const u8) !void { ... }
pub fn writeBufferFromWasm(self: *Self, allocator: Allocator, call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) !void { ... }
```

### 10. mock_gpu.zig

**Location**: `src/executor/mock_gpu.zig`

```zig
// REMOVE mock implementations (search for initWasmModule, callWasmFunc, writeBufferFromWasm)
pub fn initWasmModule(...) !void { ... }
pub fn callWasmFunc(...) !void { ... }
pub fn writeBufferFromWasm(...) !void { ... }
```

### 11. gpu.js

**Location**: `npm/pngine/src/gpu.js`

```javascript
// REMOVE from CMD enum (lines 46-48):
INIT_WASM_MODULE: 0x30,
CALL_WASM_FUNC: 0x31,

// REMOVE stub methods (lines 1076-1090):
_initWasmModule(moduleId, dataPtr, dataLen) { ... }
_callWasmFunc(callId, moduleId, namePtr, nameLen, argsPtr, argsLen) { ... }

// REMOVE from command dispatch switch if present
```

### 12. Examples

**Delete or migrate**:
- `examples/wasm_rotated_cube.pngine`
- `examples/data_wasm_cube.pngine`
- `examples/assets/mvp.wasm` (if exists)

---

## Execution Order

The removal must follow dependency order to keep the build passing at each step:

```
Step 1: Remove examples (no dependencies)
    └── Delete wasm_rotated_cube.pngine, data_wasm_cube.pngine, mvp.wasm

Step 2: Remove JS runtime (leaf node)
    └── Modify gpu.js

Step 3: Remove executor (depends on opcodes)
    ├── Modify dispatcher.zig
    ├── Modify wasm_gpu.zig
    └── Modify mock_gpu.zig

Step 4: Remove emitter (depends on opcodes, analyzer)
    ├── Delete emitter/wasm.zig
    └── Modify Emitter.zig

Step 5: Remove bytecode (opcodes used by executor, emitter)
    └── Modify opcodes.zig

Step 6: Remove DSL (parser, analyzer depend on tokens/ast)
    ├── Modify Analyzer.zig
    ├── Modify Parser.zig
    ├── Modify Ast.zig
    └── Modify Token.zig
```

**Alternative**: Remove bottom-up (Token → Ast → Parser → Analyzer → Emitter → opcodes → executor → JS) if you want compile errors to guide you.

---

## Testing Strategy

### After Each Step

```bash
# Build and run tests
/Users/hugo/.zvm/bin/zig build test --summary all

# Build CLI
/Users/hugo/.zvm/bin/zig build

# Build WASM
/Users/hugo/.zvm/bin/zig build web
```

### Verify No Regressions

```bash
# Compile working examples (should still work)
./zig-out/bin/pngine compile examples/simple_triangle.pngine -o /tmp/test.pngb
./zig-out/bin/pngine compile examples/rotating_cube.pngine -o /tmp/test.pngb
./zig-out/bin/pngine compile examples/boids.pngine -o /tmp/test.pngb

# Check bytecode
./zig-out/bin/pngine check /tmp/test.pngb
```

### Verify WASM Examples Fail Gracefully

After removal, attempting to compile old WASM examples should give clear errors:

```bash
# Should fail with "unknown macro 'wasmCall'" or similar
./zig-out/bin/pngine compile examples/wasm_rotated_cube.pngine
```

---

## Line Count Estimate

| File | Lines Removed |
|------|---------------|
| emitter/wasm.zig | 387 (delete) |
| opcodes.zig | ~80 |
| dispatcher.zig | ~50 |
| wasm_gpu.zig | ~30 |
| mock_gpu.zig | ~20 |
| Analyzer.zig | ~15 |
| Parser.zig | ~20 |
| Token.zig | ~5 |
| Ast.zig | ~3 |
| Emitter.zig | ~10 |
| gpu.js | ~50 |
| Examples | ~320 |

**Total: ~990 lines removed**

---

## Future: Migration to Compute Shaders

The removed `#wasmCall` use cases (MVP matrix calculation) should be migrated to compute shaders as described in `data-generation-plan.md`:

```
// OLD: WASM-based MVP matrix
#wasmCall mvpMatrix {
  module={ url="assets/mvp.wasm" }
  func=buildMVPMatrix
  returns="mat4x4"
  args=[canvas.width canvas.height time.total]
}

// NEW: Compute shader MVP matrix
#wgsl buildMVP {
  value="
    struct Params { width: f32, height: f32, time: f32, _pad: f32 }
    @group(0) @binding(0) var<uniform> params: Params;
    @group(0) @binding(1) var<storage, read_write> mvp: mat4x4f;

    fn perspective(fov: f32, aspect: f32, near: f32, far: f32) -> mat4x4f { ... }
    fn lookAt(eye: vec3f, target: vec3f, up: vec3f) -> mat4x4f { ... }
    fn rotateY(angle: f32) -> mat4x4f { ... }

    @compute @workgroup_size(1)
    fn main() {
      let aspect = params.width / params.height;
      let proj = perspective(0.785, aspect, 0.1, 100.0);
      let view = lookAt(vec3f(0, 2, 5), vec3f(0, 0, 0), vec3f(0, 1, 0));
      let model = rotateY(params.time);
      mvp = proj * view * model;
    }
  "
}

#computePipeline mvpPipeline {
  layout=auto
  compute={ module=buildMVP entryPoint="main" }
}

#buffer mvpBuffer {
  size=64
  usage=[UNIFORM STORAGE]
}

#bindGroup mvpGroup {
  layout={ pipeline=mvpPipeline index=0 }
  entries=[
    { binding=0 resource={ buffer=paramsBuffer } }
    { binding=1 resource={ buffer=mvpBuffer } }
  ]
}

#computePass mvpPass {
  pipeline=mvpPipeline
  bindGroups=[mvpGroup]
  dispatchWorkgroups=[1 1 1]
}

#frame main {
  perform=[mvpPass renderPass]
}
```

This migration is **separate work** and not part of this removal plan.

---

## Rollback Plan

If issues are discovered:

1. All changes are reversible via `git checkout`
2. No data migrations involved
3. Examples can be restored from git history

---

## Success Criteria

- [ ] `zig build test` passes
- [ ] `zig build` produces working CLI
- [ ] `zig build web` produces working WASM
- [ ] Working examples (simple_triangle, rotating_cube, boids) still compile and run
- [ ] WASM examples fail with clear error message
- [ ] No references to "wasm" remain in DSL/bytecode code (grep verification)
- [ ] JS bundle size reduced (no WASM stubs)

---

## Related Documents

- `docs/data-generation-plan.md` - Replacement strategy using compute shaders
- `CLAUDE.md` - Project conventions and build commands
