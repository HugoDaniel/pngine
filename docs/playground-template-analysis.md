# Demo Template vs Inercia2025 Analysis

Analysis comparing the new demo template (`demos/template/`) with the old inercia2025 demo (`/Users/hugo/Dev/scene/demos/inercia2025/`).

## Overview

| Aspect | Inercia2025 (Old) | Demo Template (New) |
|--------|-------------------|---------------------|
| **Purpose** | Full demoparty production | Simple visual showcase |
| **Audio** | Yes (2,677 lines audio.ts) | None |
| **Scenes** | 8 scenes | 6 scenes |
| **Complexity** | High (production-grade) | Low (template) |
| **TypeScript** | Yes | Plain JS (inline) |

---

## Key Improvements in Demo Template

### 1. Simplified Project Structure

Old (inercia2025):
```
├── src/           # TypeScript source (21K+ lines)
├── demo/          # .wgsl.pngine files, wgsl/, utils/, wasm/
├── scripts/
├── public/
└── vite.config.ts # 294 lines with custom plugins
```

New (template):
```
├── index.html     # Single file with inline JS
├── scenes/        # Clean .pngine files only
├── package.json   # 16 lines
└── vite.config.ts # 50 lines (simple)
```

### 2. No Build-Time Complexity

| Config | Inercia2025 | Template |
|--------|-------------|----------|
| Vite config | 294 lines (custom single-file inlining, HTML minification) | 50 lines |
| Dependencies | 7 packages (terser, html-minifier-terser, micromatch, etc.) | 1 package (vite) |
| Build scripts | Multiple (build, build:terser) | Simple compile + build |

### 3. DSL Syntax Evolution

Old (`main.wgsl.pngine`):
```
#wgsl constants { value="./wgsl/inercia_constants.wgsl" }
#scene sceneQ { duration=35 perform=[sceneQ] }
#sequencer inerciaShow { scenes=[...] entry=sceneQ }
```

New (`main.pngine`):
```
#import "./scene1_plasma.pngine"
#animation demo {
  duration=60
  loop=true
  scenes=[{ id="scene1" frame=plasma start=0 end=10 }...]
}
```

The new `#animation` macro is cleaner and declarative compared to the old `#scene` + `#sequencer` pattern.

### 4. Simplified Runtime

Old: Complex TypeScript with scene configs, uniform mappings, BPM-based timing
```typescript
const sceneConfigs: Record<string, SceneConfig> = { ... } // 335 lines
const buildInputs = (sceneName, localTime) => { ... }     // Complex input mapping
const BEATS_PER_SECOND = BPM / 60;                       // Music-driven timing
```

New: Simple inline JavaScript
```javascript
const SCENE_TIME_OFFSETS = { plasma: 0, tunnel: 10, ... };
draw(engine, { time: sceneOffset + elapsed });  // Direct time control
```

### 5. Development Workflow

Both use:
- `npm run dev` - Vite server
- `npm run watch` - entr for file watching
- Keyboard shortcuts (1-6 or Q-I for scenes)

Template adds:
- Auto-reload polling for bytecode changes
- HMR-aware reloading
- Simpler setup: just `npm install && npm run compile && npm run dev`

---

## What Template Removes

1. **Audio system** (2,677 lines): No music sync, no BPM calculations
2. **TypeScript**: All inline JS instead
3. **Complex scene parameters**: No per-scene uniform configs with sliders
4. **Post-processing controls**: No vignette/chroma aberration controls
5. **Production build optimization**: No single-file output, no aggressive minification
6. **Video texture support**: SceneW had video integration

---

## Architecture Comparison

**Inercia2025** was designed for a demoparty competition:
- Synced to 170 BPM music
- Complex scene transitions with animation parameters
- Full UI for parameter tweaking during development
- Production build creates single compressed HTML file

**Demo Template** is designed for learning/starting new demos:
- Self-contained scenes with simple fullscreen shaders
- Clear scene template with copy-paste pattern
- Minimal boilerplate
- Focus on visual effects without audio complexity

---

## Recommendations for Improving Template

### 1. Add Scene Time Inputs

The old demo had `sceneTimeInputs` which provided normalized scene progress - useful for transitions:
```
sceneTime(f32)        - Time within current scene
sceneDuration(f32)    - Total scene duration
normalizedTime(f32)   - sceneTime / sceneDuration (0.0 to 1.0)
```

### 2. Document the Animation Table Behavior

The `#animation` macro is powerful but needs documentation:
- How does `loop=true` work?
- What does `endBehavior=hold` do?
- How does JS select scenes by time?

### 3. Add a Transition Scene Example

Show how to blend between scenes using:
- Fade to black
- Cross-dissolve
- Wipe transitions

### 4. Consider TypeScript Option

For larger demos, TypeScript helps with:
- Scene config type safety
- Uniform struct definitions
- IDE autocomplete for shader inputs

### 5. Add Production Build Option

For demoparty submissions, add optional:
- Single-file HTML output (like inercia2025's viteSingleFile plugin)
- Aggressive minification
- PNG embedding with bytecode

---

## File References

- Demo template: `demos/template/`
- Old inercia2025: `/Users/hugo/Dev/scene/demos/inercia2025/`
- DSL syntax reference: `CLAUDE.md` (DSL Syntax Reference section)
