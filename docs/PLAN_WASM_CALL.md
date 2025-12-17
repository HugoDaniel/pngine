# Implementation Plan: #wasmCall Macro

## Overview

The `#wasmCall` macro enables calling external WASM modules from PNGine at runtime. This is used for compute-intensive operations like matrix calculations (MVP matrices for 3D rendering).

## Example Usage

```pngine
#wasmCall mvpMatrix {
  module={
    url="assets/mvp.wasm"
  }
  func=buildMVPMatrix
  returns="mat4x4"
  args=[ "$canvas.width", "$canvas.height", "$t.total" ]
}

#queue writeCameraUniform {
  writeBuffer={
    buffer=cameraInput
    bufferOffset=0
    dataFrom={ wasm=mvpMatrix }
  }
}
```

## Key Behaviors

1. **WASM Module Loading**: The .wasm file is fetched, embedded in PNGB, and instantiated at init time
2. **Runtime Calls**: The function is called each frame with dynamic arguments
3. **Memory Reading**: Result is read from WASM linear memory using the returned pointer
4. **Buffer Writing**: The result is written directly to a GPU buffer

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Compile Time                                                     │
├─────────────────────────────────────────────────────────────────┤
│ 1. DSL Parser recognizes #wasmCall macro                        │
│ 2. CLI fetches .wasm file and embeds in PNGB data section       │
│ 3. Emitter generates bytecode for init + per-frame calls        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Runtime (JS/WASM)                                               │
├─────────────────────────────────────────────────────────────────┤
│ Init:                                                           │
│   1. init_wasm_module opcode → instantiate WASM                 │
│                                                                 │
│ Per-frame (in queue execution):                                 │
│   1. Resolve dynamic args ($canvas.width, $t.total, etc.)       │
│   2. call_wasm_func opcode → call function, get pointer         │
│   3. write_buffer_from_wasm opcode → copy WASM mem → GPU buffer │
└─────────────────────────────────────────────────────────────────┘
```

## Implementation Steps

### Phase 1: DSL Parser (Zig)

#### 1.1 Token.zig
Add `macro_wasmCall` to the macro keywords StaticStringMap.

```zig
// In macro_keywords
.{ "wasmCall", .macro_wasmCall },
```

#### 1.2 Ast.zig
Add node tag for wasmCall declarations.

```zig
pub const Tag = enum {
    // ... existing tags
    wasm_call,     // #wasmCall name { ... }
};
```

#### 1.3 Parser.zig
Handle `#wasmCall` in `parseMacro()`:
- Parse the name identifier
- Parse the body object with: `module`, `func`, `returns`, `args`

#### 1.4 Analyzer.zig
Add symbol table for wasm calls:

```zig
pub const SymbolTable = struct {
    // ... existing tables
    wasm_call: SymbolMap = .{},
};
```

Validation:
- `module.url` must be a string
- `func` must be an identifier
- `returns` must be a valid type ("mat4x4", "f32", "vec4", etc.)
- `args` must be an array

### Phase 2: Bytecode Format

#### 2.1 New Opcodes (opcodes.zig)

```zig
pub const OpCode = enum(u8) {
    // ... existing opcodes

    // WASM Module Operations (0x26-0x28)
    init_wasm_module = 0x26,         // [module_id:varint] [data_id:varint]
    call_wasm_func = 0x27,           // [call_id:varint] [module_id:varint] [func_name_id:varint] [arg_count:u8] [args...]
    write_buffer_from_wasm = 0x28,   // [call_id:varint] [buffer_id:varint] [offset:varint] [byte_len:varint]
};
```

#### 2.2 Emitter Methods (emitter.zig)

```zig
pub fn initWasmModule(self: *Self, allocator: Allocator, module_id: u16, data_id: u16) !void;
pub fn callWasmFunc(self: *Self, allocator: Allocator, call_id: u16, module_id: u16, func_name_id: u16, args: []const WasmArg) !void;
pub fn writeBufferFromWasm(self: *Self, allocator: Allocator, call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) !void;
```

#### 2.3 Argument Encoding

WASM function arguments need special encoding for dynamic values:

```
ArgType (1 byte):
  0x00 = literal f32
  0x01 = $canvas.width (u32)
  0x02 = $canvas.height (u32)
  0x03 = $t.total (f32 - time in seconds)
  0x04 = literal i32
  0x05 = literal u32
```

For example, `args=[ "$canvas.width", "$canvas.height", "$t.total" ]` encodes as:
```
[arg_count=3][0x01][0x02][0x03]
```

### Phase 3: DSL Emitter (Zig)

#### 3.1 New Emitter State

```zig
pub const Emitter = struct {
    // ... existing fields
    wasm_module_ids: std.StringHashMapUnmanaged(u16) = .{},
    wasm_call_ids: std.StringHashMapUnmanaged(u16) = .{},
    next_wasm_module_id: u16 = 0,
    next_wasm_call_id: u16 = 0,
};
```

#### 3.2 WASM Module Collection

In `emitWasmModules()`:
1. Iterate over `#wasmCall` symbols
2. Group by module URL (multiple calls can share one module)
3. For each unique module:
   - Fetch .wasm file (at compile time)
   - Add to data section
   - Emit `init_wasm_module`

#### 3.3 Queue Emission for dataFrom

In `emitQueueAction()`, handle `dataFrom={ wasm=... }`:

```zig
if (utils.findPropertyValueInObject(e, obj_node, "dataFrom")) |data_from| {
    if (utils.findPropertyValueInObject(e, data_from, "wasm")) |wasm_ref| {
        const call_name = resolveIdentifierOrReference(e, wasm_ref);
        const call_id = e.wasm_call_ids.get(call_name) orelse return;
        const call_info = e.analysis.symbols.wasm_call.get(call_name) orelse return;

        // Emit: call_wasm_func
        try emitWasmCallWithArgs(e, call_id, call_info);

        // Emit: write_buffer_from_wasm
        const byte_len = getReturnsByteLength(call_info.returns);
        try e.builder.getEmitter().writeBufferFromWasm(
            e.gpa, call_id, buffer_id, offset, byte_len
        );
    }
}
```

### Phase 4: Executor Changes

#### 4.1 MockGPU (mock_gpu.zig)

```zig
pub const CallType = enum {
    // ... existing
    init_wasm_module,
    call_wasm_func,
    write_buffer_from_wasm,
};

pub const MockGPU = struct {
    // ... existing
    wasm_modules: std.AutoHashMapUnmanaged(u16, void) = .{},
    wasm_call_results: std.AutoHashMapUnmanaged(u16, []const u8) = .{},

    pub fn initWasmModule(self: *MockGPU, module_id: u16, data_id: u16) void;
    pub fn callWasmFunc(self: *MockGPU, call_id: u16, module_id: u16, args: []const u8) void;
    pub fn writeBufferFromWasm(self: *MockGPU, call_id: u16, buffer_id: u16, offset: u32, len: u32) void;
};
```

#### 4.2 Dispatcher (dispatcher.zig)

Handle new opcodes:

```zig
.init_wasm_module => {
    const module_id = try readVarint(reader);
    const data_id = try readVarint(reader);
    gpu.initWasmModule(@intCast(module_id), @intCast(data_id));
},
.call_wasm_func => {
    const call_id = try readVarint(reader);
    const module_id = try readVarint(reader);
    const func_name_id = try readVarint(reader);
    const arg_count = try reader.readByte();
    // Read args...
    gpu.callWasmFunc(...);
},
.write_buffer_from_wasm => {
    const call_id = try readVarint(reader);
    const buffer_id = try readVarint(reader);
    const offset = try readVarint(reader);
    const byte_len = try readVarint(reader);
    gpu.writeBufferFromWasm(...);
},
```

#### 4.3 WASM GPU Backend (wasm_gpu.zig)

Export new functions for JS:

```zig
extern fn gpuInitWasmModule(module_id: u16, data_ptr: [*]const u8, data_len: u32) void;
extern fn gpuCallWasmFunc(call_id: u16, module_id: u16, func_name_ptr: [*]const u8, func_name_len: u32, args_ptr: [*]const u8, args_len: u32) void;
extern fn gpuWriteBufferFromWasm(call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) void;
```

### Phase 5: JavaScript Implementation

#### 5.1 PNGineGPU.js

```javascript
class PNGineGPU {
    constructor() {
        // ... existing
        this.wasmModules = new Map();      // module_id -> { instance, memory }
        this.wasmCallResults = new Map();  // call_id -> pointer
    }

    initWasmModule(moduleId, dataPtr, dataLen) {
        const bytes = this.readBytes(dataPtr, dataLen);
        const imports = {
            env: {
                abort: () => { throw new Error('WASM abort'); }
            }
        };

        // Instantiate synchronously (small modules) or async
        const module = new WebAssembly.Module(bytes);
        const instance = new WebAssembly.Instance(module, imports);

        this.wasmModules.set(moduleId, {
            instance,
            memory: instance.exports.memory
        });
    }

    callWasmFunc(callId, moduleId, funcName, args) {
        const wasm = this.wasmModules.get(moduleId);
        if (!wasm) throw new Error(`WASM module ${moduleId} not found`);

        const func = wasm.instance.exports[funcName];
        if (!func) throw new Error(`WASM function ${funcName} not found`);

        // Resolve dynamic args
        const resolvedArgs = this.resolveWasmArgs(args);

        // Call function - returns pointer to result
        const ptr = func(...resolvedArgs);

        this.wasmCallResults.set(callId, { ptr, moduleId });
    }

    writeBufferFromWasm(callId, bufferId, offset, byteLen) {
        const result = this.wasmCallResults.get(callId);
        if (!result) throw new Error(`WASM call result ${callId} not found`);

        const wasm = this.wasmModules.get(result.moduleId);
        const buffer = this.buffers.get(bufferId);

        // Read from WASM memory
        const data = new Uint8Array(wasm.memory.buffer, result.ptr, byteLen);

        // Write to GPU buffer
        this.device.queue.writeBuffer(buffer, offset, data);
    }

    resolveWasmArgs(encodedArgs) {
        const resolved = [];
        for (let i = 0; i < encodedArgs.length; i++) {
            const argType = encodedArgs[i];
            switch (argType) {
                case 0x00: // literal f32
                    resolved.push(new DataView(encodedArgs.buffer, i + 1, 4).getFloat32(0, true));
                    i += 4;
                    break;
                case 0x01: // $canvas.width
                    resolved.push(this.context.canvas.width);
                    break;
                case 0x02: // $canvas.height
                    resolved.push(this.context.canvas.height);
                    break;
                case 0x03: // $t.total
                    resolved.push(this.currentTime || 0);
                    break;
                // ... more arg types
            }
        }
        return resolved;
    }
}
```

### Phase 6: CLI Integration

#### 6.1 Asset Fetching

The CLI needs to fetch .wasm files at compile time:

```zig
// In src/cli.zig or src/dsl/Compiler.zig
fn fetchWasmAsset(url: []const u8) ![]const u8 {
    // For file:// URLs, read from filesystem
    // For http:// URLs, use std.http.Client
    // Return bytes to embed in data section
}
```

#### 6.2 Compilation Flow

```
1. Parse DSL
2. Analyze (collect #wasmCall declarations)
3. For each unique WASM module URL:
   a. Fetch .wasm file
   b. Add to data section
4. Emit bytecode
5. Finalize PNGB
```

### Phase 7: Testing

#### 7.1 Unit Tests

- Opcode encoding/decoding
- Argument encoding/decoding
- MockGPU call recording
- Dispatcher execution

#### 7.2 Integration Tests

- Compile example with #wasmCall
- Execute in MockGPU, verify call sequence
- Verify buffer contents match expected

#### 7.3 End-to-End Test

- Build mvp.wasm (AssemblyScript or Rust)
- Compile wasm_rotated_cube.pngine
- Run in browser, verify cube rotates correctly

## Return Type Mapping

| DSL Type  | Byte Length | TypedArray     |
|-----------|-------------|----------------|
| f32       | 4           | Float32Array   |
| vec2      | 8           | Float32Array   |
| vec3      | 12          | Float32Array   |
| vec4      | 16          | Float32Array   |
| mat3x3    | 36          | Float32Array   |
| mat4x4    | 64          | Float32Array   |

## Dynamic Argument Types

| Code | Name            | Value Source           | Type |
|------|-----------------|------------------------|------|
| 0x00 | literal_f32     | Next 4 bytes           | f32  |
| 0x01 | canvas_width    | canvas.width           | u32  |
| 0x02 | canvas_height   | canvas.height          | u32  |
| 0x03 | time_total      | current time in sec    | f32  |
| 0x04 | literal_i32     | Next 4 bytes           | i32  |
| 0x05 | literal_u32     | Next 4 bytes           | u32  |
| 0x06 | time_delta      | delta since last frame | f32  |

## Dependencies

- No new Zig dependencies
- No new JS dependencies
- Requires mvp.wasm or similar test asset

## Risk Assessment

### Medium Risk
- **WASM instantiation timing**: May need async handling like ImageBitmap
- **Memory management**: WASM memory grows independently of JS heap

### Low Risk
- **Argument encoding**: Well-defined, limited set of types
- **Buffer writes**: Same pattern as existing writeBuffer

## Estimated Complexity

| Component          | Files Changed | New Lines | Difficulty |
|-------------------|---------------|-----------|------------|
| Token/Parser      | 3             | ~50       | Low        |
| Analyzer          | 1             | ~30       | Low        |
| Opcodes           | 1             | ~20       | Low        |
| Emitter           | 2             | ~150      | Medium     |
| DSL Emitter       | 2             | ~200      | Medium     |
| Dispatcher        | 1             | ~80       | Medium     |
| MockGPU           | 1             | ~60       | Low        |
| JS Implementation | 1             | ~150      | Medium     |
| CLI Asset Fetch   | 1             | ~50       | Low        |
| Tests             | 3             | ~300      | Medium     |

**Total: ~1090 new lines across 16 files**

## Alternative Approaches Considered

### 1. Inline WASM in DSL
Rejected: Too complex, WASM is binary

### 2. JS-only WASM handling
Rejected: Breaks bytecode portability

### 3. Precompute matrices
Rejected: Doesn't work for dynamic canvas size/time
