# Uniform Reflection Plan (Zig + Miniray)

## Overview

Embed WGSL reflection data in bytecode so runtime can set uniform values by name without recompilation.

## Why Runtime Reflection (Not Just Compile-Time)

| Advantage | Description |
|-----------|-------------|
| **Multiplatform** | Same Zig code works on Web/iOS/Android/Desktop - platforms just call `setUniform(name, data)` |
| **No recompilation** | Change uniform values without recompiling shaders or regenerating bytecode |
| **Dynamic UI** | Build sliders/controls dynamically by enumerating uniforms at runtime |
| **Debugging** | Introspect what uniforms exist, their types, offsets - useful for tooling |
| **Hot reload** | Update uniform values frame-by-frame without reloading the module |
| **Decoupling** | Platform code doesn't need to know buffer layouts - just field names |

## Current State

1. **Miniray** (external CLI) reflects WGSL at compile time → returns JSON with bindings, layouts, fields
2. **DSL Emitter** already calls miniray and caches `ReflectionData` per shader
3. Used for **auto buffer sizing** (`size=shader.binding` → resolves to actual byte size)

## What's Missing

The reflection data is available at compile time but **not embedded in bytecode** or exposed at runtime.

---

## Design: Embed Reflection in Bytecode

### 1. New Bytecode Section: Uniform Table

Add after data section in PNGB format:

```
Header (updated):
  magic: "PNGB"
  version: u16
  flags: u16
  string_table_offset: u32
  data_section_offset: u32
  uniform_table_offset: u32    // NEW - 0 if no uniforms

Uniform Table:
  [binding_count: u16]
  For each binding:
    [buffer_id: u16]           // Which buffer this binding maps to
    [name_string_id: u16]      // Binding var name (e.g., "uniforms") in string table
    [group: u8]                // @group(n)
    [binding_index: u8]        // @binding(n)
    [field_count: u16]
    For each field:
      [name_string_id: u16]    // Field name (e.g., "time", "color")
      [offset: u16]            // Byte offset in buffer
      [size: u16]              // Byte size
      [type: u8]               // UniformType enum
      [_pad: u8]               // Alignment padding

UniformType enum:
  0 = f32     (4 bytes)
  1 = i32     (4 bytes)
  2 = u32     (4 bytes)
  3 = vec2f   (8 bytes)
  4 = vec3f   (12 bytes)
  5 = vec4f   (16 bytes)
  6 = mat3x3f (48 bytes, 3 vec4 columns)
  7 = mat4x4f (64 bytes)
  8 = vec2i   (8 bytes)
  9 = vec3i   (12 bytes)
  10 = vec4i  (16 bytes)
  11 = vec2u  (8 bytes)
  12 = vec3u  (12 bytes)
  13 = vec4u  (16 bytes)
```

### 2. Compile Time (DSL Emitter)

When emitting a `#buffer` that references a shader binding:

```zig
// In emitBuffer():
if (buffer has size=shader.binding reference) {
    const reflection = self.getWgslReflection(shader_name);
    const binding = reflection.getBindingByName(binding_name);

    // Record binding → buffer_id mapping
    self.uniform_bindings.append(.{
        .buffer_id = buffer_id,
        .binding_name = binding.name,
        .group = binding.group,
        .binding = binding.binding,
        .fields = binding.layout.fields,
    });
}

// At end of emit:
self.emitUniformTable(); // Serialize to bytecode
```

### 3. Runtime (WASM Exports)

```zig
// Parse uniform table from bytecode on loadModule()
var uniform_table: ?UniformTable = null;

export fn loadModule(ptr: [*]const u8, len: usize) u32 {
    // ... existing load logic ...
    uniform_table = UniformTable.parse(allocator, module) catch null;
}

/// Set uniform field value by name.
/// name_ptr/len: field name (e.g., "time", "color")
/// value_ptr/len: raw bytes to write
/// Returns: 0=success, 1=not found, 2=size mismatch
export fn setUniform(
    name_ptr: [*]const u8,
    name_len: u32,
    value_ptr: [*]const u8,
    value_len: u32
) u32;

/// Get total number of uniform fields across all bindings.
export fn getUniformFieldCount() u32;

/// Get uniform field name by index.
export fn getUniformFieldName(index: u32, out_ptr: [*]u8, out_len: u32) u32;

/// Get uniform field info by index.
/// Returns packed: buffer_id(16) | offset(16) | size(16) | type(8) | _pad(8)
export fn getUniformFieldInfo(index: u32) u64;
```

### 4. Platform Integration

**JavaScript:**
```javascript
// In draw():
if (opts.uniforms) {
  for (const [name, value] of Object.entries(opts.uniforms)) {
    const data = toFloat32Array(value);  // Handle scalar, array, nested
    const nameBytes = encoder.encode(name);
    wasm.setUniform(nameBytes.ptr, nameBytes.length, data.ptr, data.byteLength);
  }
}
```

**Swift/Kotlin/C++:** Same pattern - just call `setUniform(name, data)`.

---

## Implementation Steps

| Step | File | Description |
|------|------|-------------|
| 1 | `bytecode/format.zig` | Add `uniform_table_offset` to header, bump version |
| 2 | `bytecode/uniform_table.zig` | New file: UniformTable struct, parsing, serialization |
| 3 | `dsl/Emitter.zig` | Track buffer↔binding mappings during emit |
| 4 | `dsl/Emitter.zig` | Call `emitUniformTable()` at end of emission |
| 5 | `wasm.zig` | Parse uniform table on loadModule, add exports |
| 6 | `npm/.../anim.js` | Update `draw()` to call `setUniform` for each uniform |
| 7 | Tests | Emitter tests, WASM integration tests |

---

## Example Flow

**WGSL shader:**
```wgsl
struct Uniforms {
    time: f32,
    color: vec4<f32>,
}
@group(0) @binding(0) var<uniform> u: Uniforms;
```

**Miniray output (compile time):**
```json
{
  "bindings": [{
    "group": 0, "binding": 0, "name": "u",
    "layout": {
      "size": 32,
      "fields": [
        {"name": "time", "offset": 0, "size": 4, "type": "f32"},
        {"name": "color", "offset": 16, "size": 16, "type": "vec4<f32>"}
      ]
    }
  }]
}
```

**DSL:**
```
#buffer uniforms { size=code.u usage=[UNIFORM COPY_DST] }
```

**Bytecode uniform table:**
```
binding_count: 1
  buffer_id: 0
  name_string_id: 5 ("u")
  group: 0, binding: 0
  field_count: 2
    name_string_id: 6 ("time"), offset: 0, size: 4, type: f32
    name_string_id: 7 ("color"), offset: 16, size: 16, type: vec4f
```

**Runtime:**
```javascript
draw(p, { uniforms: { time: 1.5, color: [1, 0, 0, 1] } });
// → wasm.setUniform("time", [1.5]) → writes 4 bytes to buffer 0 at offset 0
// → wasm.setUniform("color", [1,0,0,1]) → writes 16 bytes to buffer 0 at offset 16
```

---

## Status

- [ ] Step 1: bytecode/format.zig - header update
- [ ] Step 2: bytecode/uniform_table.zig - new module
- [ ] Step 3: dsl/Emitter.zig - track bindings
- [ ] Step 4: dsl/Emitter.zig - emit table
- [ ] Step 5: wasm.zig - parse + exports
- [ ] Step 6: npm/.../anim.js - JS integration
- [ ] Step 7: Tests
