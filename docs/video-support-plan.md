# Video Support Implementation Plan

## Overview

This document outlines how to add video support to pngine, enabling video textures in shaders. The main challenge is that WebGPU's `GPUExternalTexture` (for video frames) must be recreated each frame, requiring dynamic bind group recreation.

## Background: Old PNGine Video Architecture

The old pngine (`../old_pngine/src/`) implemented video support with:

| File | Purpose |
|------|---------|
| `preprocessor/parseVideoAsset.ts` | DSL parsing for `#videoAsset` macro |
| `viewer.ts` | Main thread video element management and frame transfer |
| `worker.ts` | WebWorker message handling for video frames |
| `interpreter.ts` | GPU-side video texture binding and updates |
| `compiler/compiler.ts` | Compilation of video assets into PNG chunks |

**DSL Syntax:**
```wgsl
#videoAsset fertagus {
  url="./assets/fertagus_nuclear.webm"
  mimeType="video/webm"
  loop=true
}

#bindGroup videoBindGroup {
  layout={ pipeline=renderSceneW index=1 }
  entries=[
    { binding=0 resource=videoSampler }
    { binding=1 resource=fertagus }
  ]
}
```

**Key APIs used:**
- `HTMLVideoElement` for playback
- `VideoFrame` (WebCodecs) for frame transfer
- `requestVideoFrameCallback()` for sync
- `device.importExternalTexture()` for GPU binding
- `Transferable` for zero-copy worker transfer

---

## The Core Problem

WebGPU's `GPUExternalTexture` has unique constraints:

```javascript
// This MUST be called every frame - external textures are ephemeral
const externalTexture = device.importExternalTexture({ source: videoFrame });

// Bind groups are IMMUTABLE - you can't update a resource in-place
const bindGroup = device.createBindGroup({
  layout,
  entries: [{ binding: 0, resource: externalTexture }]
});
// No bindGroup.updateEntry(0, newTexture) API exists!
```

**Bind groups containing video must be recreated each frame.**

---

## Current Architecture Limitation

**command_buffer.zig:218-224** - Bind group creation:
```zig
pub fn createBindGroup(self: *Self, id: u16, layout_id: u16, entries_ptr: u32, entries_len: u32) void {
    self.writeCmd(.create_bind_group);
    // ...
}
```

**gpu.js:591-629** - JS handler with early exit:
```javascript
_createBindGroup(id, layoutId, entriesPtr, entriesLen) {
  if (this.bindGroups.has(id)) return;  // PROBLEM: Skips recreation
  // ...
}
```

**gpu.js:958-970** - Existing recreation pattern for image bitmaps:
```javascript
_recreateBindGroupsForTexture(textureId) {
  for (const [bindGroupId, desc] of this.bindGroupDescriptors.entries()) {
    const referencesTexture = desc.entries.some(
      (e) => e.resourceType === 1 && e.resourceId === textureId
    );
    if (referencesTexture) {
      this.bindGroups.delete(bindGroupId);
      this._recreateBindGroup(bindGroupId, desc);
    }
  }
}
```

---

## Proposed Solution: Frame-Level Bind Group Creation

**Key insight**: Instead of creating all bind groups once during resource setup, emit `create_bind_group` in the **frame command buffer** for bind groups that contain video textures.

### Changes Required

#### 1. Command Buffer Protocol (No Changes Needed!)

The existing `create_bind_group` opcode (0x07) works perfectly. The change is **when** it's emitted:
- Static bind groups: emitted during resource setup (first `renderFrame`)
- Dynamic bind groups: emitted in every frame's command buffer

#### 2. JS CommandDispatcher (gpu.js)

**Change**: Remove early exit for bind groups, or track "static" vs "dynamic":

```javascript
// Option A: Remove early exit entirely (simpler, slightly more work per frame)
_createBindGroup(id, layoutId, entriesPtr, entriesLen) {
  // Remove: if (this.bindGroups.has(id)) return;

  // Destroy old bind group if exists (GPUBindGroup has no destroy, just overwrite)
  // ... rest of creation logic
}

// Option B: Add flag for dynamic bind groups (more efficient)
_createBindGroup(id, layoutId, entriesPtr, entriesLen, dynamic = false) {
  if (!dynamic && this.bindGroups.has(id)) return;
  // ...
}
```

**Add**: New resource type for external textures:

```javascript
// In _createBindGroup when building gpuEntries:
} else if (e.resourceType === 3) { // external_texture (video)
  const videoName = this.getVideoNameById(e.resourceId);
  const videoData = this.videoFrames.get(videoName);
  if (!videoData) throw new Error(`Video ${videoName} not ready`);

  // Create external texture from current video frame
  const externalTexture = this.device.importExternalTexture({
    source: videoData.frame
  });
  entry.resource = externalTexture;
}
```

#### 3. Bind Group Descriptor Encoding (DescriptorEncoder.zig)

Add new resource type for external textures:

```zig
pub const ResourceType = enum(u8) {
    buffer = 0,
    texture_view = 1,
    sampler = 2,
    external_texture = 3,  // NEW: for video
};
```

#### 4. DSL Emitter (resources.zig)

Track which bind groups are dynamic:

```zig
// During bind group analysis
fn isBindGroupDynamic(self: *Emitter, bg: *BindGroup) bool {
    for (bg.entries) |entry| {
        if (entry.resource_type == .video) return true;
    }
    return false;
}

// During emission
fn emitBindGroup(self: *Emitter, bg: *BindGroup) !void {
    if (self.isBindGroupDynamic(bg)) {
        // Don't emit here - will be emitted in frame commands
        self.dynamic_bind_groups.append(bg.id);
        return;
    }
    // Normal emission for static bind groups
    try self.bytecode.emit(.create_bind_group, ...);
}
```

#### 5. Frame Emission (frames.zig or passes.zig)

Emit dynamic bind groups at start of each frame:

```zig
fn emitFrame(self: *Emitter, frame: *Frame) !void {
    // First: recreate dynamic bind groups
    for (self.dynamic_bind_groups.items) |bg_id| {
        try self.bytecode.emit(.create_bind_group, ...);
    }

    // Then: normal frame operations
    for (frame.operations) |op| {
        try self.emitOperation(op);
    }
}
```

#### 6. Video Frame Transfer (worker.js)

```javascript
// Handle video frame from main thread
case 'videoFrame': {
  const { name, frame, width, height } = data;

  // Close previous frame to prevent memory leak
  const old = this.videoFrames.get(name);
  if (old?.frame) old.frame.close();

  // Store new frame
  this.videoFrames.set(name, { frame, width, height });

  // No need to mark dirty - bind groups are recreated each frame
  break;
}
```

---

## Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ COMPILE TIME (DSL → Bytecode)                                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  #video fertagus { url="video.webm" loop=true }                            │
│                    ↓                                                        │
│  Analyzer: video_resources["fertagus"] = { id: 0, url, loop }              │
│                    ↓                                                        │
│  #bindGroup scene { entries=[{binding=0 resource=fertagus}] }              │
│                    ↓                                                        │
│  Analyzer: marks bind group "scene" as dynamic                              │
│                    ↓                                                        │
│  Emitter:                                                                   │
│    - Resource section: declares video metadata (not bind group)             │
│    - Frame section: emits create_bind_group for "scene"                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ RUNTIME (Bytecode → GPU)                                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Main Thread                           Worker Thread                        │
│  ────────────                          ─────────────                        │
│  VideoManager:                                                              │
│    video.requestVideoFrameCallback →   ← worker.postMessage({               │
│    frame = new VideoFrame(video)         type: 'videoFrame',               │
│    worker.postMessage({                   name: 'fertagus',                │
│      type: 'videoFrame',                  frame, width, height             │
│      frame                              }, [frame])                         │
│    }, [frame]) // Transferable                  ↓                           │
│                                         videoFrames.set('fertagus', ...)    │
│                                                 ↓                           │
│  play(p) →                             ← onmessage({ type: 'draw' })        │
│  requestAnimationFrame →                        ↓                           │
│  draw(p, { time }) →                   wasm.renderFrame(time, 0)            │
│  postMessage({ type: 'draw' })                  ↓                           │
│                                         Command Buffer:                     │
│                                         ┌─────────────────────────────┐     │
│                                         │ 0x07 create_bind_group      │←─┐  │
│                                         │   id: scene_bg_id           │  │  │
│                                         │   entries: [                │  │  │
│                                         │     { type: 3, id: 0 }      │  │ Each│
│                                         │   ]                         │  │ Frame│
│                                         ├─────────────────────────────┤  │  │
│                                         │ 0x10 begin_render_pass      │  │  │
│                                         │ 0x12 set_pipeline           │  │  │
│                                         │ 0x13 set_bind_group(scene)  │  │  │
│                                         │ 0x15 draw                   │  │  │
│                                         │ 0x17 end_pass              │  │  │
│                                         │ 0xF0 submit                 │──┘  │
│                                         └─────────────────────────────┘     │
│                                                 ↓                           │
│                                         gpu.execute(cmdPtr)                 │
│                                                 ↓                           │
│                                         case 0x07: // create_bind_group     │
│                                           if (type === 3) {                 │
│                                             frame = videoFrames.get(...)    │
│                                             tex = importExternalTexture()   │
│                                           }                                 │
│                                           device.createBindGroup(...)       │
│                                                 ↓                           │
│                                         GPU renders with current video frame│
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Alternative: New Opcode for Dynamic Bind Groups

If we want to be explicit about static vs dynamic, add a new opcode:

```zig
// In command_buffer.zig
pub const Cmd = enum(u8) {
    // ...existing opcodes...
    create_dynamic_bind_group = 0x0F,  // Same format as create_bind_group
};
```

```javascript
// In gpu.js
case CMD.CREATE_DYNAMIC_BIND_GROUP: {
  // Same as CREATE_BIND_GROUP but never skips
  const id = view.getUint16(pos, true);
  // Always delete and recreate
  this.bindGroups.delete(id);
  this._createBindGroup(id, ...);
  return pos + 12;
}
```

---

## File Changes Summary

| File | Change |
|------|--------|
| `dsl/Token.zig` | Add `macro_video` keyword |
| `dsl/Ast.zig` | Add `video` node tag |
| `dsl/Parser.zig` | Parse `#video` macro |
| `dsl/Analyzer.zig` | Track video resources, mark bind groups as dynamic |
| `dsl/emitter/resources.zig` | Emit video metadata, skip dynamic bind groups |
| `dsl/emitter/frames.zig` | Emit dynamic bind groups at frame start |
| `dsl/DescriptorEncoder.zig` | Add `external_texture = 3` resource type |
| `executor/command_buffer.zig` | (Optional) Add `create_dynamic_bind_group` |
| `npm/pngine/src/gpu.js` | Handle external_texture type, remove early exit |
| `npm/pngine/src/worker.js` | Handle videoFrame messages |
| `npm/pngine/src/init.js` | Add VideoManager class |

---

## Estimated Complexity

| Component | Risk | Notes |
|-----------|------|-------|
| DSL parsing | Low | Standard macro pattern |
| Analyzer changes | Medium | Need to track cross-references |
| Emitter frame emission | Medium | New emission timing logic |
| JS external texture handling | Low | Well-defined WebGPU API |
| Video frame transfer | Medium | Transferable handling, lifecycle |
| Main thread VideoManager | Medium | Browser autoplay policies |

---

## Open Questions

1. **Embedded vs URL-only videos?**
   - Embedded: Video bytes in PNG (larger files, self-contained)
   - URL-only: Just reference external video (smaller, requires hosting)
   - Both: Support both via separate macros or flags

2. **Video ready synchronization?**
   - First draw should wait for video to be ready, or show fallback?
   - Timeout handling for slow video loading

3. **Multiple videos?**
   - Each video needs its own frame callback loop
   - How to handle sync between multiple video sources

4. **Autoplay handling?**
   - Need API to resume videos on user interaction (browser policy)
   - Expose `resumeVideos()` on the pngine object

5. **Pool compatibility?**
   - Can video bind groups use pool offsets? (Probably not meaningful)

---

## Implementation Phases

### Phase 1: DSL & Bytecode
1. Add `#video` macro to DSL (Token, Ast, Parser)
2. Track video resources in Analyzer
3. Mark bind groups as dynamic when they reference video
4. Add `external_texture` resource type to DescriptorEncoder

### Phase 2: Emitter Changes
1. Emit video metadata in resource section
2. Skip dynamic bind groups in resource emission
3. Emit dynamic bind groups in frame section

### Phase 3: JS Runtime
1. Add `videoFrames` map to CommandDispatcher
2. Handle `external_texture` resource type in `_createBindGroup`
3. Remove early exit for dynamic bind groups
4. Add `videoFrame` message handler to worker

### Phase 4: Main Thread Video Management
1. Create `VideoManager` class
2. Handle `requestVideoFrameCallback` loop
3. Transfer `VideoFrame` to worker via `Transferable`
4. Handle autoplay policies

### Phase 5: PNG Embedding (Optional)
1. Add video chunk type to PNG embedding
2. Extract and create Blob URL at runtime
3. Handle large file sizes

---

## Related Documents

- `docs/js-api-refactor-plan.md` - Command buffer protocol details
- `CLAUDE.md` - Project overview and conventions
