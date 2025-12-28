# Command Buffer Protocol Refactor Plan

> **Note**: TypedArray/fill operations (0x50-0x55) have been removed.
> Use `#init` macro with compute shaders for buffer initialization.

## Executive Summary

Refactor the JS command dispatcher (gpu.js) from 1,221 lines to ~200-600 lines, reducing bundle size from 9.3KB gzip to <5KB gzip while maintaining full functionality.

---

## Current State vs Plan Target

| Metric | Current | Target | Gap |
|--------|---------|--------|-----|
| Bundle (gzip) | 9.3 KB | <5 KB | -46% needed |
| JS Lines | 2,420 | ~910 | -62% needed |
| gpu.js Lines | 1,221 | ~200 | -84% needed |
| Opcodes | 41 | ~21 | -49% needed |
| draw() API | ✅ sync | sync | Done |
| Animation | ✅ works | works | Done |
| Uniforms | ✅ works | works | Done |

---

## Root Cause Analysis

### Why is gpu.js 6x larger than target?

1. **Complex descriptor decoders** (~400 lines)
   - `_decodeTextureDescriptor`: 50 lines
   - `_decodeSamplerDescriptor`: 35 lines
   - `_decodeBindGroupDescriptor`: 45 lines
   - Pipeline JSON parsing + building: 100 lines
   - Format/usage translation tables: 100 lines

2. **Extra opcodes** (~300 lines)
   - TypedArray operations (CREATE_TYPED_ARRAY, FILL_RANDOM, etc.)
   - WASM module operations (INIT_WASM_MODULE, CALL_WASM_FUNC)
   - Image bitmap handling (CREATE_IMAGE_BITMAP, COPY_EXTERNAL_IMAGE)
   - Render bundles, query sets, pipeline layouts

3. **Bind group recreation logic** (~100 lines)
   - `_recreateBindGroupsForTexture`
   - `_recreateBindGroup`
   - Storing descriptors for recreation

4. **Debug logging & error handling** (~100 lines)

### The Fundamental Tension

The plan envisions a thin JS dispatcher, but WebGPU requires JavaScript objects. You cannot call `device.createBuffer()` from WASM - you must go through JS. The command buffer is already the right abstraction.

**However, we can simplify by:**
1. Moving more logic to WASM (format conversion, usage flags)
2. Removing unused opcodes
3. Using JSON descriptors instead of binary encoding (simpler JS, WASM does encoding)
4. Removing TypedArray/WASM module features (rarely used)

---

## Refactor Strategies

### Option A: Minimal Refactor (Low Risk, ~30% Size Reduction)

Keep current architecture, just trim:

1. **Remove unused opcodes** (WASM modules, TypedArrays if unused)
2. **Simplify decoders** - Use JSON for all descriptors (parsed from WASM string)
3. **Remove debug code in production** (use `DEBUG` define)
4. **Consolidate resource tables** - Single `resources` Map instead of per-type

Expected result: ~6KB gzip

### Option B: Aggressive Refactor (Higher Risk, ~50% Size Reduction)

Restructure for minimal JS:

1. **Single unified resource table** - All GPU objects in one Map by ID
2. **JSON-only descriptors** - No binary decoding in JS
3. **Remove recreation logic** - Push to WASM or defer to video support
4. **Opcode consolidation** - Fewer, more generic opcodes
5. **Kill unused features** - TypedArrays, WASM modules, render bundles

Expected result: ~4.5KB gzip

### Option C: Plan's Vision (Highest Risk, ~5KB Target)

Complete rewrite as described in js-api-refactor-plan.md:

1. **Compact binary uniform table** from WASM (vs multiple function calls)
2. **Compact binary animation info** from WASM
3. **Minimal 21-opcode command set**
4. **Zero descriptor decoding in JS** - All done in WASM
5. **Resource array instead of Map** - `resources[id]` vs `resources.get(id)`

Expected result: <5KB gzip

---

## Recommended Approach: Option A + Selective Option B

### Phase 1: Quick Wins (1-2 hours)

1. **Audit opcode usage** - Remove opcodes not used by any example
2. **Add production build** - Define `DEBUG=false` to strip logging
3. **Consolidate resource Maps** - Single `resources` Map

### Phase 2: Descriptor Simplification (2-3 hours)

1. **JSON for all complex descriptors** - Texture, sampler, pipeline
2. **Move format/usage translation to WASM** - JS just passes through
3. **Simplify bind group descriptor** - Direct entries array

### Phase 3: Recreation Logic (1-2 hours)

1. **Remove bind group recreation** - Defer to video support phase
2. **Remove texture descriptor storage** - Not needed without recreation

### Phase 4: Measure & Iterate

1. **Measure bundle size after each phase**
2. **Stop when target reached or diminishing returns**

---

## Detailed Implementation

### Phase 1: Opcode Audit

**Files to analyze:**
- `src/executor/command_buffer.zig` - Which opcodes exist
- `src/bytecode/emitter.zig` - Which opcodes are emitted
- `src/dsl/emitter/*.zig` - Which resources generate opcodes

**Likely removable opcodes:**
- `init_wasm_module`, `call_wasm_func` - Embedded WASM modules (advanced feature)
- `create_typed_array`, `fill_*`, `write_buffer_from_array` - Data generation
- `create_render_bundle`, `execute_bundles` - Optimization feature
- `create_query_set` - Profiling feature
- `create_bind_group_layout`, `create_pipeline_layout` - Use `layout: "auto"`

**Savings estimate:** ~200 lines (~20 lines × 10 opcodes)

### Phase 2: Descriptor Simplification

**Current (gpu.js):**
```javascript
_decodeTextureDescriptor(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset);
  let offset = 0;
  const typeTag = bytes[offset++];
  // ... 50 lines of binary parsing
}
```

**Target:**
```javascript
_createTexture(id, descPtr, descLen) {
  const json = this._readString(descPtr, descLen);
  const desc = JSON.parse(json);
  this.textures.set(id, this.device.createTexture(desc));
}
```

**WASM change:** Emit JSON string instead of binary descriptor
**JS savings:** ~150 lines (remove all `_decode*Descriptor` functions)

### Phase 3: Resource Table Consolidation

**Current:**
```javascript
this.buffers = new Map();
this.textures = new Map();
this.samplers = new Map();
// ... 12 more Maps
```

**Target:**
```javascript
this.resources = new Map(); // or array: this.resources = []
```

**Savings:** ~50 lines (table management, destroy logic)

### Phase 4: Production Build

**esbuild config:**
```javascript
define: {
  'DEBUG': 'false',
  'process.env.NODE_ENV': '"production"'
},
pure: ['console.log', 'console.debug', 'console.info'],
```

**Savings:** ~100 lines of debug code eliminated at build time

---

## Command Set Comparison

### Current Opcodes (41)

```
Resource Creation (0x01-0x0E): 14 opcodes
  create_buffer, create_texture, create_sampler, create_shader,
  create_render_pipeline, create_compute_pipeline, create_bind_group,
  create_texture_view, create_query_set, create_bind_group_layout,
  create_image_bitmap, create_pipeline_layout, create_render_bundle

Pass Operations (0x10-0x1A): 11 opcodes
  begin_render_pass, begin_compute_pass, set_pipeline, set_bind_group,
  set_vertex_buffer, draw, draw_indexed, end_pass, dispatch,
  set_index_buffer, execute_bundles

Queue Operations (0x20-0x25): 6 opcodes
  write_buffer, write_time_uniform, copy_buffer_to_buffer,
  copy_texture_to_texture, write_buffer_from_wasm,
  copy_external_image_to_texture

WASM Module (0x30-0x31): 2 opcodes
  init_wasm_module, call_wasm_func

Utility (0x40-0x44): 5 opcodes
  create_typed_array, fill_random, fill_expression,
  fill_constant, write_buffer_from_array

Control (0xF0, 0xFF): 2 opcodes
  submit, end
```

### Target Opcodes (~21)

```
Resource Creation (0x01-0x06): 6 opcodes
  CREATE_BUFFER, CREATE_TEXTURE, CREATE_SAMPLER,
  CREATE_BIND_GROUP, CREATE_PIPELINE, CREATE_SHADER

Resource Update (0x10-0x11): 2 opcodes
  WRITE_BUFFER, WRITE_TEXTURE

Render Pass (0x20-0x27): 8 opcodes
  BEGIN_RENDER_PASS, SET_PIPELINE, SET_BIND_GROUP,
  SET_VERTEX_BUFFER, SET_INDEX_BUFFER, DRAW,
  DRAW_INDEXED, END_RENDER_PASS

Compute Pass (0x30-0x32): 3 opcodes
  BEGIN_COMPUTE_PASS, DISPATCH, END_COMPUTE_PASS

Control (0xF0-0xFF): 2 opcodes
  SUBMIT, END
```

---

## File Changes Required

| File | Change | Priority |
|------|--------|----------|
| `npm/pngine/src/gpu.js` | Remove unused opcodes | P1 |
| `npm/pngine/src/gpu.js` | Consolidate resource Maps | P1 |
| `npm/pngine/scripts/bundle.js` | Add DEBUG=false | P1 |
| `src/dsl/DescriptorEncoder.zig` | Output JSON instead of binary | P2 |
| `npm/pngine/src/gpu.js` | Remove binary decoders | P2 |
| `npm/pngine/src/gpu.js` | Remove recreation logic | P3 |
| `src/wasm.zig` | Add get_uniform_table export | P3 |
| `src/wasm.zig` | Add get_animation_info export | P3 |

---

## Success Metrics

After refactor:
1. `gzip -c dist/browser.mjs | wc -c` < 6000 (Phase 1-2)
2. `wc -l npm/pngine/src/gpu.js` < 600 (Phase 1-2)
3. All existing examples still work
4. No performance regression (measure renderFrame time)

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Breaking existing bytecode | Keep opcodes backward compatible |
| Performance regression | Benchmark before/after |
| Feature loss | Document removed features |
| JSON parsing overhead | Only at resource creation, not per-frame |

---

## Questions to Answer Before Starting

1. **Which opcodes are actually used?** Need to audit examples and emitter.
2. **Is binary descriptor encoding used?** If emitter already uses JSON, decoder removal is safe.
3. **Is recreation logic needed?** If no ImageBitmap resizing in examples, can defer.
4. **What's the performance budget?** Is JSON parsing acceptable for resource creation?

---

## Related Documents

- `docs/js-api-refactor-plan.md` - Original API refactor vision
- `docs/video-support-plan.md` - Video support (requires bind group recreation)
- `src/executor/command_buffer.zig` - Zig command buffer implementation
- `npm/pngine/src/gpu.js` - Current JS command dispatcher
