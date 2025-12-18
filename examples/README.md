# Inercia Demoparty Demo - 260 Seconds

This is a structured 8-scene demo designed for the Inercia demoparty, with keyboard control for rehearsal and music synchronization.

## Quick Start

```bash
# Build the demo
make demo

# Run with live reload
make dev

# Then open http://localhost:3000/demo.html
```

## Scene Structure

Each scene is self-contained in its own `.wgsl.pngine` file:

| Key | Scene  | Time     | Duration | Color  | Current Effect     |
| --- | ------ | -------- | -------- | ------ | ------------------ |
| Q   | sceneQ | 0-35s    | 35s      | Red    | Pulsating vignette |
| W   | sceneW | 35-65s   | 30s      | Orange | Diagonal gradient  |
| E   | sceneE | 65-95s   | 30s      | Yellow | Radial pattern     |
| R   | sceneR | 95-130s  | 35s      | Green  | Organic waves      |
| T   | sceneT | 130-160s | 30s      | Cyan   | Horizontal bands   |
| Y   | sceneY | 160-190s | 30s      | Blue   | Concentric circles |
| U   | sceneU | 190-220s | 30s      | Purple | Spiral             |
| I   | sceneI | 220-260s | 40s      | White  | Expanding light    |

## Keyboard Controls

- **Q, W, E, R, T, Y, U, I**: Jump to specific scenes
- **Space**: Play/Pause
- **0**: Restart from beginning

The time display shows current position in the 260-second timeline.

## Development Workflow

### Expanding Individual Scenes

Each scene file can be edited independently. For example, to make sceneQ more complex:

```wgsl
// In sceneQ.wgsl.pngine
#shaderModule sceneQ {
  code="
    // Add complex effects, textures, compute shaders, etc.
    // The scene will automatically integrate with the timeline
  "
}
```

### Adjusting Timings

Edit `main.wgsl.pngine` to change scene transitions:

```wgsl
#animation sceneSelector {
  duration=260
  keys=[
    { t=0    v=0 hold=true }  // Change these timings
    { t=35   v=1 hold=true }  // to match your music
    // ...
  ]
}
```

### Adding Smooth Transitions

Currently scenes switch instantly (`hold=true`). To add crossfades:

```wgsl
{ t=35   v=0.5 easing="cubic-bezier(0.42,0,0.58,1)" }  // Smooth transition
```

## Architecture Benefits

1. **Modular**: Each scene evolves independently
2. **Timeline-based**: Precise synchronization with music
3. **Keyboard-driven**: Easy rehearsal and event recording
4. **Extensible**: Add effects without breaking other scenes

## For Musicians

The demo logs all scene changes to the browser console:

```
🎬 Jumped to sceneQ at 0s
🎬 Jumped to sceneW at 35s
...
```

Press keys to mark important musical moments, then sync your audio to the logged timestamps.

## Next Steps

### Phase 1: Structure (DONE ✓)

- ✓ 8 scene files created
- ✓ Timeline orchestration
- ✓ Keyboard navigation
- ✓ Time display

### Phase 2: Visual Development

- [ ] Expand each scene with unique effects
- [ ] Add transitions between scenes
- [ ] Integrate assets (textures, 3D models, etc.)
- [ ] Fine-tune timings with musician

### Phase 3: Polish

- [ ] Add post-processing effects
- [ ] Optimize performance
- [ ] Test on target hardware
- [ ] Final synchronization with music

## File Organization

```
demo/
├── sceneQ.wgsl.pngine    # Individual scene definitions
├── sceneW.wgsl.pngine
├── sceneE.wgsl.pngine
├── sceneR.wgsl.pngine
├── sceneT.wgsl.pngine
├── sceneY.wgsl.pngine
├── sceneU.wgsl.pngine
├── sceneI.wgsl.pngine
├── main.wgsl.pngine      # Timeline orchestrator
└── README.md             # This file

../
├── demo.html             # Playback interface
├── demo.png              # Compiled demo (15KB)
└── Makefile              # Build commands
```

## Technical Notes

### Frame-Based Scene Architecture

Unlike a traditional approach where all scenes are compiled into a single shader with switching logic, this demo uses **true frame-based scene switching**:

1. **Each scene is a separate `#frame`**:
   - `sceneQ.wgsl.pngine` defines `#frame sceneQ { ... }`
   - `sceneW.wgsl.pngine` defines `#frame sceneW { ... }`
   - etc.

2. **Main file imports all scenes**:

   ```wgsl
   #import "./sceneQ.wgsl.pngine"
   #import "./sceneW.wgsl.pngine"
   // ... etc
   ```

3. **JavaScript renders the active frame**:

   ```javascript
   // Determine which scene should be active
   const currentSceneKey = getCurrentScene(currentTime);
   const frameName = getFrameName(currentSceneKey);

   // Draw only that scene's frame
   anim.draw(currentTime, frameName);
   ```

4. **Benefits**:
   - **No shader duplication**: Each scene's shader code exists only once
   - **True loading/unloading**: Only the active frame's resources are used
   - **Modular**: Scenes are completely independent
   - **Smaller file size**: 13KB vs 15KB with the old composite approach
   - **Easier to maintain**: Change one scene without touching others

## Tips for Development

1. **Test individual scenes**: Temporarily set a scene's start time to 0 for focused development
2. **Use console logs**: All scene switches are logged for audio sync
3. **Live reload**: `make dev` rebuilds on save and refreshes browser
4. **Keep it modular**: Don't add cross-scene dependencies

Good luck at Inercia! 🎉
