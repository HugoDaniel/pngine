# Uniform Reflection Plan (Zig + Miniray)

> **Status**: ✅ COMPLETE - All phases implemented
>
> **Context**:
> - Main project guide: `CLAUDE.md`
> - Bytecode format: `src/bytecode/format.zig`
> - Uniform table: `src/bytecode/uniform_table.zig`

---

## Overview

Embed WGSL reflection data in bytecode so runtime can set uniform values by name without recompilation.

## Why Runtime Reflection (Not Just Compile-Time)

| Advantage | Description |
|-----------|-------------|
| **Multiplatform** | Same code works on Web/iOS/Android/Desktop - platforms just call `setUniform(name, data)` |
| **No recompilation** | Change uniform values without recompiling shaders or regenerating bytecode |
| **Dynamic UI** | Build sliders/controls dynamically by enumerating uniforms at runtime |
| **Debugging** | Introspect what uniforms exist, their types, offsets - useful for tooling |
| **Hot reload** | Update uniform values frame-by-frame without reloading the module |
| **Decoupling** | Platform code doesn't need to know buffer layouts - just field names |

---

## Design Decisions

### 1. Compile-Time Slot Indices (Not Runtime String Lookup)

Each uniform field gets a stable numeric slot assigned at compile time:

```
slot 0: "time"       → buffer=1, offset=0,  size=4,  type=f32
slot 1: "color"      → buffer=1, offset=16, size=16, type=vec4f
slot 2: "transform"  → buffer=2, offset=0,  size=64, type=mat4x4f
```

Benefits:
- O(1) lookup by slot at runtime
- String→slot mapping cached on first use
- Slots are stable across recompilations (sorted by name)

### 2. Nested Struct Flattening

Nested WGSL structs are flattened to dot-notation paths at compile time:

```wgsl
struct Position { x: f32, y: f32, z: f32 }
struct Inputs { time: f32, position: Position, color: vec4f }
@group(0) @binding(0) var<uniform> inputs: Inputs;
```

Becomes:
```
slot 0: "time"         → offset=0,  size=4,  type=f32
slot 1: "position.x"   → offset=16, size=4,  type=f32
slot 2: "position.y"   → offset=20, size=4,  type=f32
slot 3: "position.z"   → offset=24, size=4,  type=f32
slot 4: "color"        → offset=32, size=16, type=vec4f
```

API usage:
```javascript
setUniform(p, "position.x", 1.5);     // Individual field
setUniform(p, "position", [1, 2, 3]); // Whole struct (12 bytes)
```

### 3. TypeScript Definitions (Not Runtime Manifest)

Generate `.d.ts` alongside PNG with `--types` flag:

```bash
pngine shader.pngine -o shader.png --types
# Outputs: shader.png + shader.d.ts
```

```typescript
// shader.d.ts (auto-generated)
export interface Uniforms {
  time: number;
  "position.x": number;
  "position.y": number;
  "position.z": number;
  color: [number, number, number, number];
}

export type UniformName = keyof Uniforms;
```

Usage with type safety:
```typescript
import type { UniformName } from "./shader.d.ts";
setUniform<UniformName>(p, "time", 1.5);        // ✓ OK
setUniform<UniformName>(p, "typo", 1.5);        // ✗ Error
setUniform<UniformName>(p, "color", 1.5);       // ✗ Type error
```

### 4. Conflict Detection in Validator

`pngine check` warns when bytecode writes to uniform buffer fields:

```
$ pngine check shader.pngine --verbose
...
⚠️  Warning: Buffer 'uniforms' (id=1) has uniform fields but is also written by bytecode.
   Bytecode writes at frame time may override setUniform() values.
   Fields affected: time, color
   Consider using separate buffers for bytecode-managed and API-managed uniforms.
```

---

## Current Implementation Status

| Component | Status | Notes |
|-----------|--------|-------|
| **uniform_table.zig** | ✅ Complete | Serialize/deserialize, field lookup, tests |
| **format.zig header** | ✅ Complete | `uniform_table_offset` in header |
| **Emitter population** | ✅ Complete | `populateUniformTable()`, `recordUniformBinding()` |
| **Slot indices** | ✅ Complete | `slot: u16` field, assigned alphabetically at emit time |
| **Nested flattening** | ✅ Complete | `flattenFields()` in resources.zig, dot-notation paths |
| **Conflict detection** | ✅ Complete | W009 warning in `pngine check` validator |
| **TypeScript generation** | ✅ Complete | `--types` flag in CLI, `src/cli/types_gen.zig` |
| **JS setUniform** | ✅ Complete | `setUniform()` writes directly to GPU buffer |
| **JS uniform parsing** | ✅ Complete | `parseUniformTable()` in gpu.js |
| **JS getUniforms API** | ✅ Complete | `getUniforms()` returns uniform metadata |

---

## Implementation Plan

### Phase 1: Slot Indices + Nested Flattening

**Files to modify:**
1. `src/bytecode/uniform_table.zig` - Add `slot: u16` to UniformField
2. `src/dsl/emitter/resources.zig` - Flatten nested structs, assign slots
3. `src/reflect/miniray.zig` - Ensure nested struct types are resolved

**Deliverable:** Uniform table has flat fields with dot-notation paths and stable slot indices.

### Phase 2: Conflict Detection

**Files to modify:**
1. `src/cli/validate/cmd_validator.zig` - Add uniform conflict check
2. `src/cli/validate/types.zig` - Add conflict warning type

**Deliverable:** `pngine check` warns when bytecode writes to uniform buffers.

### Phase 3: TypeScript Generation

**Files to modify:**
1. `src/cli/render.zig` - Add `--types` flag
2. `src/cli/types_gen.zig` - New file: generate .d.ts from uniform table

**Deliverable:** `pngine shader.pngine --types` outputs `.d.ts` file.

### Phase 4: JS Runtime

**Files to modify:**
1. `npm/pngine/src/gpu.js` - Parse uniform table, implement setUniform
2. `npm/pngine/src/worker.js` - Handle uniform messages
3. `npm/pngine/src/anim.js` - Update setUniform to use new implementation

**Deliverable:** `setUniform("time", 1.5)` writes directly to GPU buffer.

---

## Bytecode Format

### Uniform Table (already implemented)

```
[binding_count: u16]
For each binding:
  [buffer_id: u16]
  [name_string_id: u16]
  [group: u8]
  [binding_index: u8]
  [field_count: u16]
  For each field:
    [slot: u16]            // NEW - compile-time assigned index
    [name_string_id: u16]  // "time" or "position.x" (flattened)
    [offset: u16]          // Absolute byte offset in buffer
    [size: u16]
    [type: u8]             // UniformType enum
    [_pad: u8]
```

### UniformType enum

```
0 = f32     (4 bytes)
1 = i32     (4 bytes)
2 = u32     (4 bytes)
3 = vec2f   (8 bytes)
4 = vec3f   (12 bytes)
5 = vec4f   (16 bytes)
6 = mat3x3f (48 bytes)
7 = mat4x4f (64 bytes)
8-13 = vec2i/vec3i/vec4i/vec2u/vec3u/vec4u
```

---

## Example Flow

**WGSL shader:**
```wgsl
struct Position { x: f32, y: f32, z: f32 }
struct Uniforms { time: f32, pos: Position, color: vec4f }
@group(0) @binding(0) var<uniform> u: Uniforms;
```

**Compile time (emitter):**
1. Miniray reflects → gets nested struct info
2. Flatten: `pos` (type=Position) → `pos.x`, `pos.y`, `pos.z`
3. Assign slots (sorted by name): color=0, pos.x=1, pos.y=2, pos.z=3, time=4
4. Emit to uniform table

**Runtime (JS):**
```javascript
// First call: parse uniform table, build name→slot map
setUniform(p, "pos.x", 1.5);
// → lookup "pos.x" → slot 1 → buffer 0, offset 16, size 4
// → device.queue.writeBuffer(buffers[0], 16, new Float32Array([1.5]))
```

---

## Phase Checklist

- [x] Phase 1: Slot indices + nested flattening ✅ COMPLETE
  - [x] Add `slot` field to UniformField
  - [x] Implement struct flattening in emitter
  - [x] Sort fields by name for stable slots
  - [x] Tests for nested struct flattening
- [x] Phase 2: Conflict detection ✅ COMPLETE
  - [x] Track uniform buffer IDs
  - [x] Check write_buffer calls against uniform buffers (W009)
  - [x] Add warning to validator output
- [x] Phase 3: TypeScript generation ✅ COMPLETE
  - [x] Add `--types` CLI flag
  - [x] Generate .d.ts with Uniforms interface
  - [x] Map UniformType to TypeScript types
- [x] Phase 4: JS runtime ✅ COMPLETE
  - [x] Parse uniform table in gpu.js (`parseUniformTable()`, `parseStringTable()`)
  - [x] Build name→{bufferId, offset, size, type} map at load time
  - [x] Implement setUniform with GPU buffer writes (`device.queue.writeBuffer()`)
  - [x] Handle all uniform types (f32, i32, u32, vectors, matrices)
  - [x] Add `getUniforms()` API for runtime introspection
