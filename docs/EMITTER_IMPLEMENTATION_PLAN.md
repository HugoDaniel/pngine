# Emitter Implementation Plan

This document details the missing emitter functions and macros that need to be implemented, based on analysis of:
- `old_pngine/docs/ALL_MACROS.md`
- Current Zig implementation in `src/dsl/`
- WebGPU specifications at `specs-llm/wgsl/`
- Integration tests in `src/dsl/emitter/integration_test.zig`

## Summary

### Missing Emitter Functions (4 skipped tests)

| Function | Macro | Status | Priority |
|----------|-------|--------|----------|
| `emitTextureViews` | `#textureView` | Macro missing in Token.zig | High |
| `emitQuerySets` | `#querySet` | Macro exists, emitter missing | High |
| `emitBindGroupLayouts` | `#bindGroupLayout` | Macro exists, emitter missing | High |
| `emitPipelineLayouts` | `#pipelineLayout` | Macro exists, emitter missing | High |

### Missing Macros (not in Token.zig)

| Macro | Purpose | Priority |
|-------|---------|----------|
| `#textureView` | Create GPUTextureView from texture | High |
| `#view` | Canvas/swapchain configuration | Medium |
| `#asset` | Binary payload embedding | Low |

## Phase 1: Emitter Functions for Existing Macros

### 1.1 emitBindGroupLayouts

**WebGPU Reference**: `GPUBindGroupLayoutDescriptor`

**Attributes** (from `parseBindGroupLayout.ts`):
```
entries=[
  {
    binding=<number>
    visibility=[VERTEX FRAGMENT COMPUTE]
    buffer={ type="uniform"|"storage"|"read-only-storage" hasDynamicOffset=bool minBindingSize=<number> }
    sampler={ type="filtering"|"non-filtering"|"comparison" }
    texture={ sampleType="float"|"unfilterable-float"|"depth"|"sint"|"uint" viewDimension="1d"|"2d"|"2d-array"|"cube"|"cube-array"|"3d" multisampled=bool }
    storageTexture={ format=<GPUTextureFormat> access="write-only"|"read-only"|"read-write" viewDimension=... }
    externalTexture={}
  }
]
label=<string>
```

**Implementation**:
1. Add symbol table: `bind_group_layout` (already exists in Analyzer.zig)
2. Add ID tracking: `bind_group_layout_ids` in Emitter.zig
3. Emit `create_bind_group_layout` opcode (0x06) with encoded descriptor

**Descriptor Encoding** (for DescriptorEncoder.zig):
```
[entry_count:u8]
  [binding:u16]
  [visibility:u8]  // GPUShaderStage bitmask
  [resource_type:u8]  // buffer=0, sampler=1, texture=2, storageTexture=3, externalTexture=4
  [type-specific data...]
```

### 1.2 emitPipelineLayouts

**WebGPU Reference**: `GPUPipelineLayoutDescriptor`

**Attributes** (from `parsePipelineLayout.ts`):
```
bindGroupLayouts=[layout0 layout1]
label=<string>
```

**Implementation**:
1. Symbol table: `pipeline_layout` (already exists)
2. ID tracking: `pipeline_layout_ids` in Emitter.zig
3. Emit `create_pipeline_layout` opcode (0x07)

**Descriptor Encoding**:
```
[layout_count:u8]
  [bind_group_layout_id:u16]...
```

### 1.3 emitQuerySets

**WebGPU Reference**: `GPUQuerySetDescriptor`

**Attributes** (from `parseQuerySet.ts`):
```
type="occlusion"|"timestamp"
count=<number>
label=<string>
```

**Implementation**:
1. Symbol table: `query_set` (needs to be added to Analyzer.zig)
2. ID tracking: `query_set_ids` in Emitter.zig
3. Emit `create_query_set` opcode (0x0D)

**Descriptor Encoding**:
```
[type:u8]  // 0=occlusion, 1=timestamp
[count:u16]
```

### 1.4 emitTextureViews

**WebGPU Reference**: `GPUTextureViewDescriptor`

**Attributes** (from `parseView.ts` + WebGPU spec):
```
texture=myTextureName
format=<GPUTextureFormat>  // optional, defaults to texture's format
dimension="1d"|"2d"|"2d-array"|"cube"|"cube-array"|"3d"
aspect="all"|"stencil-only"|"depth-only"
baseMipLevel=<number>
mipLevelCount=<number>
baseArrayLayer=<number>
arrayLayerCount=<number>
```

**Implementation**:
1. Add macro to Token.zig: `macro_texture_view`
2. Add node tag to Ast.zig: `macro_texture_view`
3. Add symbol table: `texture_view` in Analyzer.zig
4. Add ID tracking: `texture_view_ids` in Emitter.zig
5. Emit `create_texture_view` opcode (0x0C)

**Descriptor Encoding**:
```
[texture_id:u16]
[format:u8]  // 0xFF = inherit from texture
[dimension:u8]  // TextureViewDimension enum
[aspect:u8]
[baseMipLevel:u8]
[mipLevelCount:u8]  // 0xFF = all remaining
[baseArrayLayer:u16]
[arrayLayerCount:u16]  // 0xFFFF = all remaining
```

## Phase 2: New Macros

### 2.1 #textureView Macro

**Syntax**:
```
#textureView name {
  texture=myTexture
  dimension="cube"
  baseMipLevel=0
  mipLevelCount=4
}
```

**Files to modify**:
1. `Token.zig`: Add `macro_texture_view` to Tag enum and `macro_keywords`
2. `Ast.zig`: Add `macro_texture_view` to Node.Tag
3. `Parser.zig`: Handle in `parseMacro` switch
4. `Analyzer.zig`: Add `texture_view` symbol table
5. `Emitter.zig`: Add `texture_view_ids` and `next_texture_view_id`
6. `resources.zig`: Implement `emitTextureViews`

### 2.2 #view Macro (Canvas Configuration)

**Purpose**: Configure the swapchain/canvas context for rendering.

**Syntax** (from old_pngine):
```
#view canvas {
  source=canvas|offscreen
  size=[width height]
  format=bgra8unorm
  alpha=opaque|premultiplied
}
```

**WebGPU Reference**: `GPUCanvasContext.configure()`

**Implementation Notes**:
- This is a PNGine-specific macro (not directly a WebGPU primitive)
- Maps to `context.configure({device, format, alphaMode})`
- Provides `getCurrentTexture()` for render pass attachments
- Low priority - current tests work without it

### 2.3 #asset Macro (Binary Payloads)

**Purpose**: Embed binary assets (images, models, etc.) in PNGB.

**Syntax** (from old_pngine):
```
#asset myImage {
  url="textures/image.png"
  mimeType="image/png"
}
```

**Implementation Notes**:
- Similar to `#data` with `blob=` property
- Could be syntactic sugar for `#data name { blob={file={url="..."}} mime="..." }`
- Low priority - current `#data` blob support handles this case

## Phase 3: Analyzer Symbol Tables

Need to add to `Analyzer.zig`:

```zig
// In SymbolTable struct:
query_set: std.StringHashMapUnmanaged(SymbolInfo),
texture_view: std.StringHashMapUnmanaged(SymbolInfo),
view: std.StringHashMapUnmanaged(SymbolInfo),
asset: std.StringHashMapUnmanaged(SymbolInfo),

// In namespace_map (for reference resolution):
.{ "querySet", &self.symbols.query_set },
.{ "textureView", &self.symbols.texture_view },
.{ "view", &self.symbols.view },
.{ "asset", &self.symbols.asset },
```

## Phase 4: Dispatcher Handlers

Already added in previous session:
- `create_texture_view` (0x0C) - handler exists
- `create_query_set` (0x0D) - handler exists
- `create_bind_group_layout` (0x06) - handler exists
- `create_pipeline_layout` (0x07) - handler exists

## Implementation Order

1. **emitBindGroupLayouts** - Required by explicit pipeline layouts
2. **emitPipelineLayouts** - Used when `layout=auto` is not sufficient
3. **Add #textureView macro** - Token, Ast, Parser, Analyzer
4. **emitTextureViews** - Creates views for cube maps, mip levels, etc.
5. **emitQuerySets** - Used for timestamp/occlusion queries
6. **#view macro** (optional) - Canvas configuration

## Testing Strategy

1. Enable skipped integration tests one by one
2. Add unit tests in corresponding `*_test.zig` files
3. Verify mock GPU records correct opcode parameters
4. Test error cases (missing required properties)

## WebGPU Spec References

- GPUBindGroupLayoutDescriptor: https://www.w3.org/TR/webgpu/#dictdef-gpubindgrouplayoutdescriptor
- GPUPipelineLayoutDescriptor: https://www.w3.org/TR/webgpu/#dictdef-gpupipelinelayoutdescriptor
- GPUTextureViewDescriptor: https://www.w3.org/TR/webgpu/#dictdef-gputextureviewdescriptor
- GPUQuerySetDescriptor: https://www.w3.org/TR/webgpu/#dictdef-gpuquerysetdescriptor

## Attribute Validation Summary

### #bindGroupLayout entries

| Property | Type | Required | Default |
|----------|------|----------|---------|
| binding | number | Yes | - |
| visibility | [VERTEX FRAGMENT COMPUTE] | Yes | - |
| buffer | object | One of: buffer, sampler, texture, storageTexture, externalTexture | - |
| buffer.type | "uniform"\|"storage"\|"read-only-storage" | No | "uniform" |
| buffer.hasDynamicOffset | bool | No | false |
| buffer.minBindingSize | number | No | 0 |
| sampler.type | "filtering"\|"non-filtering"\|"comparison" | No | "filtering" |
| texture.sampleType | "float"\|"unfilterable-float"\|"depth"\|"sint"\|"uint" | No | "float" |
| texture.viewDimension | "1d"\|"2d"\|"2d-array"\|"cube"\|"cube-array"\|"3d" | No | "2d" |
| texture.multisampled | bool | No | false |
| storageTexture.format | GPUTextureFormat | Yes (if storageTexture) | - |
| storageTexture.access | "write-only"\|"read-only"\|"read-write" | No | "write-only" |

### #pipelineLayout

| Property | Type | Required | Default |
|----------|------|----------|---------|
| bindGroupLayouts | [ref...] | Yes | - |
| label | string | No | macro name |

### #querySet

| Property | Type | Required | Default |
|----------|------|----------|---------|
| type | "occlusion"\|"timestamp" | No | "occlusion" |
| count | number | Yes | - |
| label | string | No | macro name |

### #textureView

| Property | Type | Required | Default |
|----------|------|----------|---------|
| texture | ref | Yes | - |
| format | GPUTextureFormat | No | inherit from texture |
| dimension | "1d"\|"2d"\|"2d-array"\|"cube"\|"cube-array"\|"3d" | No | "2d" |
| aspect | "all"\|"stencil-only"\|"depth-only" | No | "all" |
| baseMipLevel | number | No | 0 |
| mipLevelCount | number | No | all remaining |
| baseArrayLayer | number | No | 0 |
| arrayLayerCount | number | No | all remaining |
