# PNGine Demo Template

A simple 6-scene demo template using PNGine. No audio, just visuals.

## Scenes

1. **Plasma** - Classic plasma effect with pulsing colors
2. **Tunnel** - Infinite tunnel zoom effect
3. **Waves** - Ocean-like wave patterns
4. **Stars** - Flying through a starfield
5. **Rings** - Concentric pulsing rings with interference
6. **Morph** - Morphing geometric shapes (circle -> square -> triangle -> star)

## Prerequisites

- **pngine CLI**: Must be in PATH. Build from pngine repo: `zig build` (requires Zig 0.15+)
- **Node.js**: For Vite dev server
- **entr**: For file watching (optional, `brew install entr` on macOS)

## Quick Start

```bash
# From this directory:

# 1. Install dependencies
npm install

# 2. Build pngine WASM (if not already built)
npm run setup

# 3. Compile scenes to bytecode
npm run compile

# 4. Start dev server
npm run dev
```

## Development Workflow

### Terminal 1: Dev Server
```bash
npm run dev
```
Opens browser at http://localhost:5174

### Terminal 2: Watch for Changes
```bash
npm run watch
```
Auto-recompiles bytecode when .pngine files change.

The browser will poll for bytecode changes and auto-reload.

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `1`-`6` | Switch to scene 1-6 |
| `Space` | Play/Pause |
| `R` | Reload bytecode |

## File Structure

```
demos/template/
├── index.html          # Main page with controls
├── package.json        # Scripts and dependencies
├── vite.config.ts      # Vite dev server config
├── scenes/
│   ├── main.pngine     # Orchestrator (imports all scenes)
│   ├── scene1_plasma.pngine
│   ├── scene2_tunnel.pngine
│   ├── scene3_waves.pngine
│   ├── scene4_stars.pngine
│   ├── scene5_rings.pngine
│   └── scene6_morph.pngine
└── dist/
    └── demo.pngb       # Compiled bytecode (generated)
```

## Adding New Scenes

1. Create `scenes/scene7_yourscene.pngine` with:
   - `#buffer uniforms` for time/resolution
   - `#queue writeUniforms` to update uniforms
   - `#shaderModule shader` with your WGSL code
   - `#frame yourscene { perform=[...] }`

2. Add import to `scenes/main.pngine`:
   ```
   #import "./scene7_yourscene.pngine"
   ```

3. Add button in `index.html` and update `SCENES` array in JS

## Scene Template

```
#buffer uniforms {
  size=16
  usage=[UNIFORM COPY_DST]
}

#queue writeUniforms {
  writeBuffer={ buffer=uniforms bufferOffset=0 data=pngineInputs }
}

#shaderModule shader {
  code="
    struct Uniforms {
      time: f32,
      width: f32,
      height: f32,
      aspect: f32,
    }
    @group(0) @binding(0) var<uniform> u: Uniforms;

    @vertex
    fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
      let x = f32(i & 1u) * 4.0 - 1.0;
      let y = f32((i >> 1u) & 1u) * 4.0 - 1.0;
      return vec4f(x, y, 0.0, 1.0);
    }

    @fragment
    fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let uv = pos.xy / vec2f(u.width, u.height);
      // Your effect here
      return vec4f(uv, sin(u.time) * 0.5 + 0.5, 1.0);
    }
  "
}

#renderPipeline pipeline {
  layout=auto
  vertex={ entryPoint=vs module=shader }
  fragment={
    entryPoint=fs
    module=shader
    targets=[{ format=preferredCanvasFormat }]
  }
}

#bindGroup uniformsBindGroup {
  layout={ pipeline=pipeline index=0 }
  entries=[{ binding=0 resource={ buffer=uniforms } }]
}

#renderPass mainPass {
  colorAttachments=[{
    view=contextCurrentTexture
    clearValue=[0 0 0 1]
    loadOp=clear
    storeOp=store
  }]
  pipeline=pipeline
  bindGroups=[uniformsBindGroup]
  draw=3
}

#frame yourscene {
  perform=[writeUniforms mainPass]
}
```

## Tips

- Each scene gets `pngineInputs`: `time`, `width`, `height`, `aspect`
- The fullscreen triangle trick: 3 vertices with `i & 1u` and `(i >> 1u) & 1u`
- Use `smoothstep`, `fract`, `sin` for animations
- SDFs (signed distance functions) are great for shape effects
