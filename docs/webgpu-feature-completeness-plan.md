# WebGPU Feature Completeness Plan

## Overview

This document details the features needed to support all 51 WebGPU samples from the
official webgpu-samples repository. It builds on top of `data-generation-plan.md`
which handles procedural data generation.

**Goal**: Enable pngine to express any WebGPU sample with minimal payload and executor size.

**Constraints** (from data-generation-plan.md):
- Payload (.pngb) must be small
- Executor (WASM) must be small
- No complex VM in runtime

---

## Current State Analysis

### Features Already Implemented ✅

| Feature | DSL | Bytecode | Executor | Notes |
|---------|-----|----------|----------|-------|
| Render pipelines | ✅ | ✅ | ✅ | Full support |
| Compute pipelines | ✅ | ✅ | ✅ | Full support |
| Vertex/Index buffers | ✅ | ✅ | ✅ | draw/drawIndexed |
| Uniform/Storage buffers | ✅ | ✅ | ✅ | All usage flags |
| Ping-pong buffers | ✅ | ✅ | ✅ | Pool operations |
| 2D Textures | ✅ | ✅ | ✅ | With canvas size |
| Depth textures | ✅ | ✅ | ✅ | depth24plus, depth32float |
| Depth/stencil format | ✅ | ✅ | ✅ | depth24plus-stencil8 |
| Stencil state (pipeline) | ✅ | ✅ | ✅ | stencilFront/Back ops |
| Samplers | ✅ | ✅ | ✅ | filter, addressMode |
| Comparison samplers | ✅ | ✅ | ⚠️ | Partial (missing `compare` in JS) |
| Bind groups | ✅ | ✅ | ✅ | With explicit layouts |
| Texture views | ✅ | ✅ | ✅ | With dimension override |
| Cube textures | ✅ | ✅ | ⚠️ | viewDimension only, missing JS |
| MSAA | ✅ | ✅ | ⚠️ | Missing resolveTarget |
| Query sets | ✅ | ✅ | ⚠️ | Create only, no resolve |
| Render bundles | ✅ | ✅ | ✅ | Pre-recorded draws |
| Image bitmaps | ✅ | ✅ | ✅ | External images |

### Features Missing ❌

| Feature | Samples Using | Priority | Executor Lines |
|---------|---------------|----------|----------------|
| Multiple Render Targets | 5 | **High** | +25 |
| 3D Textures | 2 | Medium | +10 |
| 2D Array Textures | 3 | Medium | +5 |
| Cube Array Textures | 1 | Low | +5 |
| Viewport/Scissor | 3 | Medium | +15 |
| setStencilReference | 3 | Medium | +5 |
| Timestamp queries (resolve) | 3 | Low | +30 |
| Indirect drawing | 2 | Low | +20 |
| MSAA resolveTarget | 2 | Medium | +10 |
| Customizable clear values | 10+ | Medium | +15 |
| Depth/stencil load/store ops | 5+ | Medium | +10 |
| Mip level count | 5 | Medium | +5 |

---

## Tier 1: High Priority (MRT + Core Rendering)

### 1.1 Multiple Render Targets (MRT)

**Samples**: deferredRendering, clusteredShading, cornell

**Current limitation**: `_beginRenderPass` only supports 1 color attachment.

**DSL Syntax** (already works for parsing):
```
#renderPass gbufferPass {
  colorAttachments=[
    { view=normalTexture clearValue=[0 0 1 1] loadOp=clear storeOp=store }
    { view=albedoTexture clearValue=[0 0 0 1] loadOp=clear storeOp=store }
  ]
  depthStencilAttachment={
    view=depthTexture
    depthClearValue=1.0
    depthLoadOp=clear
    depthStoreOp=store
  }
  pipeline=gbufferPipeline
  drawIndexed=36000
}
```

**Bytecode Changes**:
```
BEGIN_RENDER_PASS (0x10) - Extended format:
┌─────────────────────────────────────────────────────────────┐
│ opcode: u8 = 0x10                                           │
│ format_version: u8 = 0x02 (extended format)                 │
│ color_count: u8                                             │
│ for each color attachment:                                  │
│   texture_id: u16                                           │
│   load_op: u8                                               │
│   store_op: u8                                              │
│   clear_r: f16, clear_g: f16, clear_b: f16, clear_a: f16   │
│ depth_texture_id: u16 (0xFFFF = none)                       │
│ depth_load_op: u8                                           │
│ depth_store_op: u8                                          │
│ depth_clear_value: f16                                      │
│ stencil_load_op: u8 (if stencil format)                    │
│ stencil_store_op: u8                                        │
│ stencil_clear_value: u8                                     │
└─────────────────────────────────────────────────────────────┘
```

**Executor Changes** (~25 lines):
```javascript
// gpu.js _beginRenderPass - extend for MRT
_beginRenderPassV2(view, colorCount, depthId, ...) {
  const colorAttachments = [];
  for (let i = 0; i < colorCount; i++) {
    colorAttachments.push({
      view: this._getTextureView(colorIds[i]),
      loadOp: loadOps[i],
      storeOp: storeOps[i],
      clearValue: clearValues[i],
    });
  }
  // ... existing depth handling
}
```

**Payload Impact**: +8 bytes per extra color attachment (acceptable for complex scenes)

---

### 1.2 MSAA Resolve Targets

**Samples**: helloTriangleMSAA, volumeRenderingTexture3D

**Current limitation**: No `resolveTarget` in color attachment.

**DSL Syntax**:
```
#texture msaaTarget {
  size=[canvas.width canvas.height]
  format=preferredCanvasFormat
  usage=[RENDER_ATTACHMENT]
  sampleCount=4
}

#renderPass msaaPass {
  colorAttachments=[{
    view=msaaTarget
    resolveTarget=contextCurrentTexture  // NEW
    loadOp=clear
    storeOp=discard  // MSAA texture can be discarded after resolve
  }]
}
```

**Bytecode**: Add `resolve_target_id: u16` after `store_op` in color attachment.

**Executor Changes** (~10 lines):
```javascript
if (resolveTargetId !== 0xFFFF) {
  attachment.resolveTarget = this._getTextureView(resolveTargetId);
}
```

---

### 1.3 Customizable Clear Values

**Current limitation**: Hardcoded `clearValue: { r: 0, g: 0, b: 0, a: 1 }`.

**Already in DSL** (just needs executor support):
```
colorAttachments=[{ clearValue=[0.5 0.5 0.5 1.0] ... }]
```

**Executor Changes**: Parse clear values from bytecode instead of hardcoding.

---

## Tier 2: Medium Priority (Texture Dimensions + Render State)

### 2.1 Texture Dimensions (3D, Array, Cube)

**Samples**: volumeRenderingTexture3D (3d), generateMipmap (2d-array, cube, cube-array)

**DSL Syntax**:
```
#texture volume {
  size=[180 216 180]       // 3D: [width height depth]
  dimension=3d             // NEW: "1d", "2d", "3d"
  format=r8unorm
  usage=[TEXTURE_BINDING COPY_DST]
}

#texture layers {
  size=[256 256 10]        // Array: [width height layers]
  dimension=2d-array       // NEW
  format=rgba8unorm
  usage=[TEXTURE_BINDING]
}

#texture envmap {
  size=[256 256 6]         // Cube: 6 faces
  dimension=cube           // NEW (distinct from viewDimension)
  format=rgba8unorm
  usage=[TEXTURE_BINDING]
}
```

**Bytecode** (texture descriptor):
```
FIELD_DIMENSION = 0x09
Value: enum { "1d"=0, "2d"=1, "2d-array"=2, "3d"=3, "cube"=4, "cube-array"=5 }
```

**Executor Changes** (~10 lines):
```javascript
if (desc.dimension) {
  textureDesc.dimension = ["1d", "2d", "2d-array", "3d", "cube", "cube-array"][desc.dimension];
}
```

---

### 2.2 Viewport and Scissor Rect

**Samples**: generateMipmap, occlusionQuery, clusteredShading

**DSL Syntax**:
```
#renderPass mipPass {
  viewport={ x=0 y=0 width=128 height=128 minDepth=0 maxDepth=1 }  // NEW
  scissorRect={ x=0 y=0 width=128 height=128 }                     // NEW
  ...
}
```

**Bytecode**:
```
SET_VIEWPORT (0x1B):
┌───────────────────────────────────────┐
│ opcode: u8 = 0x1B                     │
│ x: u16, y: u16                        │
│ width: u16, height: u16               │
│ minDepth: f16, maxDepth: f16          │
└───────────────────────────────────────┘

SET_SCISSOR_RECT (0x1C):
┌───────────────────────────────────────┐
│ opcode: u8 = 0x1C                     │
│ x: u16, y: u16                        │
│ width: u16, height: u16               │
└───────────────────────────────────────┘
```

**Executor Changes** (~15 lines):
```javascript
case CMD.SET_VIEWPORT:
  this.pass.setViewport(x, y, width, height, minDepth, maxDepth);
  return pos + 12;

case CMD.SET_SCISSOR_RECT:
  this.pass.setScissorRect(x, y, width, height);
  return pos + 8;
```

---

### 2.3 Stencil Reference

**Samples**: stencilMask, cornell

**DSL Syntax**:
```
#renderPass maskPass {
  stencilReference=1  // NEW
  ...
}
```

**Bytecode**:
```
SET_STENCIL_REFERENCE (0x1D):
┌───────────────────────────────────────┐
│ opcode: u8 = 0x1D                     │
│ reference: u32                        │
└───────────────────────────────────────┘
```

**Executor Changes** (~5 lines):
```javascript
case CMD.SET_STENCIL_REFERENCE:
  this.pass.setStencilReference(view.getUint32(pos, true));
  return pos + 4;
```

---

### 2.4 Mip Level Count

**Samples**: generateMipmap, texturedCube, normalMap

**DSL Syntax**:
```
#texture mipmapped {
  size=[256 256]
  mipLevelCount=9  // NEW: log2(256) + 1
  format=rgba8unorm
  usage=[TEXTURE_BINDING COPY_DST RENDER_ATTACHMENT]
}
```

**Bytecode**: Add `FIELD_MIP_LEVEL_COUNT = 0x0B` to texture descriptor.

**Executor Changes** (~5 lines):
```javascript
if (desc.mipLevelCount) textureDesc.mipLevelCount = desc.mipLevelCount;
```

---

### 2.5 Comparison Sampler (Complete)

**Samples**: shadowMapping

**DSL already supports**:
```
#sampler shadowSampler { compare=less }
```

**Executor fix** (~5 lines):
```javascript
// _decodeSamplerDescriptor - add compare field
if (fieldId === FIELD_COMPARE) {
  desc.compare = ["never","less","equal","less-equal","greater","not-equal","greater-equal","always"][value];
}
```

---

## Tier 3: Low Priority (Advanced Features)

### 3.1 Timestamp Queries

**Samples**: timestampQuery, computeBoids, bitonicSort

**Components needed**:
1. `timestampWrites` in pass descriptor
2. `resolveQuerySet` command
3. Buffer mapping for CPU readback

**DSL Syntax**:
```
#querySet timestamps {
  type=timestamp
  count=2
}

#buffer timestampBuffer {
  size=16
  usage=[COPY_SRC QUERY_RESOLVE]
}

#buffer timestampReadback {
  size=16
  usage=[COPY_DST MAP_READ]
}

#renderPass timedPass {
  timestampWrites={
    querySet=timestamps
    beginningOfPassWriteIndex=0
    endOfPassWriteIndex=1
  }
  ...
}

#frame main {
  perform=[
    timedPass
    resolveQuerySet={ querySet=timestamps startQuery=0 queryCount=2 destination=timestampBuffer }
    copyBufferToBuffer={ src=timestampBuffer dst=timestampReadback }
  ]
}
```

**New Opcodes**:
```
RESOLVE_QUERY_SET (0x26):
  query_set_id: u16
  start_query: u16
  query_count: u16
  destination_buffer_id: u16
  destination_offset: u32

MAP_BUFFER_ASYNC (0x27):  // For CPU readback
  buffer_id: u16
  callback_id: u16  // Links to JS callback
```

**Executor Impact**: ~30 lines

**Note**: This is primarily a profiling feature. Most samples don't need it.

---

### 3.2 Indirect Drawing

**Samples**: bundleCulling (potential), clustering (potential)

**DSL Syntax**:
```
#buffer indirectBuffer {
  size=20  // 5 × u32 for drawIndexedIndirect
  usage=[INDIRECT COPY_DST]
}

#renderPass indirectPass {
  pipeline=myPipeline
  drawIndexedIndirect={ buffer=indirectBuffer offset=0 }  // NEW
}

#computePass indirectDispatch {
  pipeline=computePipeline
  dispatchIndirect={ buffer=dispatchBuffer offset=0 }  // NEW
}
```

**New Opcodes**:
```
DRAW_INDIRECT (0x1E):
  buffer_id: u16
  offset: u32

DRAW_INDEXED_INDIRECT (0x1F):
  buffer_id: u16
  offset: u32

DISPATCH_INDIRECT (0x20):  // Note: 0x18 is regular dispatch
  buffer_id: u16
  offset: u32
```

**Executor Impact**: ~20 lines

---

## Integration with Data Generation Plan

The features in this document work synergistically with `data-generation-plan.md`:

### Tier 1 Generators (Compile-Time)

| Generator | MRT | 3D Tex | Notes |
|-----------|-----|--------|-------|
| `cubeMesh` | ✅ | - | GBuffer geometry |
| `sphereMesh` | ✅ | - | Particle instances |
| `planeMesh` | ✅ | - | Fullscreen quads for deferred |
| `sequence` | ✅ | - | Index buffers |

### Tier 2 Compute Init (Runtime)

| Use Case | MRT | 3D Tex | Viewport | Notes |
|----------|-----|--------|----------|-------|
| Particle init | - | - | - | Existing |
| Heightmap | - | - | ✅ | Render to mip levels |
| Volume data | - | ✅ | - | Fill 3D texture via compute |
| Light culling | ✅ | - | ✅ | Clustered shading |

### Combined Example: Deferred Rendering

```
// Tier 1: Static mesh (compile-time)
#buffer dragonMesh {
  fill=dragonMesh { format=pos_normal_uv }  // From data-generation-plan.md
}

// MRT: GBuffer textures (this plan)
#texture gNormal { size=[canvas.width canvas.height] format=rgba16float usage=[RENDER_ATTACHMENT TEXTURE_BINDING] }
#texture gAlbedo { size=[canvas.width canvas.height] format=bgra8unorm usage=[RENDER_ATTACHMENT TEXTURE_BINDING] }
#texture gDepth { size=[canvas.width canvas.height] format=depth24plus usage=[RENDER_ATTACHMENT TEXTURE_BINDING] }

// Tier 2: Light positions (runtime compute from data-generation-plan.md)
#buffer lights {
  size=32768
  usage=[STORAGE]
  initCompute={
    pipeline=lightInitPipeline
    bindGroup=lightInitBindGroup
    dispatch=[16 1 1]
  }
}

// GBuffer pass (MRT)
#renderPass gbufferPass {
  colorAttachments=[
    { view=gNormal clearValue=[0 0 1 1] loadOp=clear storeOp=store }
    { view=gAlbedo clearValue=[0 0 0 1] loadOp=clear storeOp=store }
  ]
  depthStencilAttachment={ view=gDepth depthClearValue=1.0 }
  pipeline=gbufferPipeline
  vertexBuffers=[dragonMesh]
  drawIndexed=36000
}

// Deferred lighting pass
#renderPass deferredPass {
  colorAttachments=[{ view=contextCurrentTexture loadOp=clear storeOp=store }]
  pipeline=deferredPipeline
  bindGroups=[gbufferBindGroup lightsBindGroup]
  draw=6  // Fullscreen quad
}
```

---

## Implementation Roadmap

### Phase 1: MRT Foundation (Enables 5 samples)
1. Extend `BEGIN_RENDER_PASS` bytecode format
2. Update `DescriptorEncoder.zig` for multiple color attachments
3. Update `Emitter.zig` pass emission
4. Update `gpu.js` `_beginRenderPass`
5. Add clear value support

**Files**: `opcodes.zig`, `DescriptorEncoder.zig`, `emitter/passes.zig`, `gpu.js`
**Lines**: ~60 Zig, ~40 JS

### Phase 2: Texture Dimensions (Enables 6 samples)
1. Add `dimension` field to texture descriptor
2. Update `_createTexture` in JS
3. Add `mipLevelCount` field

**Files**: `DescriptorEncoder.zig`, `emitter/resources.zig`, `gpu.js`
**Lines**: ~30 Zig, ~20 JS

### Phase 3: Render State Commands (Enables 6 samples)
1. Add `SET_VIEWPORT` opcode
2. Add `SET_SCISSOR_RECT` opcode
3. Add `SET_STENCIL_REFERENCE` opcode
4. Complete comparison sampler support

**Files**: `opcodes.zig`, `Emitter.zig`, `gpu.js`
**Lines**: ~40 Zig, ~25 JS

### Phase 4: MSAA Complete (Enables 2 samples)
1. Add `resolveTarget` to color attachment
2. Ensure `sampleCount` propagates correctly

**Files**: `DescriptorEncoder.zig`, `gpu.js`
**Lines**: ~20 Zig, ~15 JS

### Phase 5: Advanced (Optional, enables 5 samples)
1. Timestamp query resolution
2. Indirect drawing commands

**Files**: `opcodes.zig`, `gpu.js`
**Lines**: ~80 Zig, ~50 JS

---

## Size Impact Summary

| Phase | Zig Lines | JS Lines | WASM Impact | Payload Impact |
|-------|-----------|----------|-------------|----------------|
| 1: MRT | +60 | +40 | +1KB | +8B/attachment |
| 2: Dimensions | +30 | +20 | +0.5KB | +2B/texture |
| 3: Render State | +40 | +25 | +0.5KB | +6B/pass |
| 4: MSAA | +20 | +15 | +0.3KB | +2B/attachment |
| 5: Advanced | +80 | +50 | +1KB | +12B/query |
| **Total** | **+230** | **+150** | **+3.3KB** | Variable |

**Comparison**: The original data-generation-plan.md DataVM approach would have added ~800-1200 lines (+15-25KB WASM). This plan adds only ~230 lines (+3.3KB WASM) for far more capability.

---

## Sample Coverage After Implementation

| Phase | Samples Enabled | Cumulative |
|-------|-----------------|------------|
| Current | 35/51 | 69% |
| Phase 1 (MRT) | +5 | 78% |
| Phase 2 (Dimensions) | +4 | 86% |
| Phase 3 (Render State) | +4 | 94% |
| Phase 4 (MSAA) | +1 | 96% |
| Phase 5 (Advanced) | +2 | 100% |

---

## Appendix: Sample Feature Matrix

| Sample | MRT | 3D | Array | Viewport | Stencil | Timestamp | Indirect |
|--------|-----|----|----|----------|---------|-----------|----------|
| deferredRendering | ✅ | | | | | | |
| clusteredShading | ✅ | | | ✅ | | | |
| cornell | ✅ | | | | ✅ | | |
| volumeRenderingTexture3D | | ✅ | | | | | |
| generateMipmap | | | ✅ | ✅ | | | |
| stencilMask | | | | | ✅ | | |
| shadowMapping | | | | | | | |
| timestampQuery | | | | | | ✅ | |
| helloTriangleMSAA | MSAA | | | | | | |

---

## Related Documents

- `docs/data-generation-plan.md` - Procedural data generation (Tier 1 + Tier 2)
- `docs/multiplatform-command-buffer-plan.md` - Platform architecture
- `docs/video-support-plan.md` - Video texture handling
