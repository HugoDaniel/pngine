# Box2D v3 Physics Demos for PNGine

WebGPU-rendered 2D physics simulations powered by [Box2D v3.2.0](https://box2d.org/) compiled to WebAssembly, driven by PNGine's `#wasmCall` DSL.

## Demos

| Demo | Description | Bodies | Visual |
|------|-------------|--------|--------|
| **Domino Cascade** | 30 thin dominoes in a curve — first one pushed, chain reaction | ~30 | Satisfying sequential toppling |
| **Tower Explosion** | 4×15 brick tower settles then explodes via `b2World_Explode()` | ~60 | Dramatic particle-like burst |
| **Circle Avalanche** | Circles pour through a funnel onto zigzag ramps with pegs | ~200 | Continuous particle flow |

## Architecture

```
┌─────────────────────┐     ┌──────────────┐     ┌──────────────────┐
│  .pngine DSL file   │────▶│  WASM module │────▶│  WebGPU render   │
│                     │     │  (Box2D v3)  │     │  (instanced)     │
│  #wasmCall          │     │              │     │                  │
│    physics_step(dt) │     │  physics_*() │     │  Storage buffer  │
│    get_transforms() │     │  exports     │     │  → vertex shader │
└─────────────────────┘     └──────────────┘     └──────────────────┘
```

**Data flow per frame:**
1. `physics_step(dt)` — advances Box2D simulation
2. `physics_get_transforms()` — packs body positions into WASM linear memory
3. PNGine copies transform data to a GPU storage buffer
4. WGSL vertex shader reads transforms per `instance_index`

## Building

### Prerequisites
- Zig 0.14+ (for cross-compiling C to wasm32)
- Box2D v3 source at `../../external/box2d`

### Compile a demo to WASM

Using Zig's C cross-compiler (no Emscripten needed):

```bash
# From this directory
zig cc \
  -target wasm32-freestanding \
  -O2 \
  -DNDEBUG \
  -DBOX2D_DISABLE_SIMD \
  -I../../external/box2d/include \
  -I../../external/box2d/src \
  src/domino_cascade.c \
  ../../external/box2d/src/*.c \
  -o domino_cascade.wasm \
  --export-dynamic \
  -Wl,--no-entry
```

> **Note:** `BOX2D_DISABLE_SIMD` is recommended for initial wasm32 builds.
> WASM SIMD (`-msimd128`) can be enabled once the basic build works.

### Alternative: Emscripten

```bash
emcc \
  -O2 -DNDEBUG \
  -I../../external/box2d/include \
  -I../../external/box2d/src \
  -s EXPORTED_FUNCTIONS='["_physics_init","_physics_step","_physics_get_transforms","_physics_get_transform_ptr","_physics_get_body_count","_physics_explode"]' \
  -s ALLOW_MEMORY_GROWTH=1 \
  src/tower_explosion.c \
  ../../external/box2d/src/*.c \
  -o tower_explosion.js
```

## Source Files

```
demos/box2d-physics/
├── README.md                          # This file
├── src/
│   ├── physics_common.h               # Shared WASM shim (exports, helpers)
│   ├── domino_cascade.c               # Demo 1: Domino chain reaction
│   ├── tower_explosion.c              # Demo 2: Tower + explosion
│   └── circle_avalanche.c             # Demo 3: Circle particle avalanche
└── domino_cascade.pngine              # Example PNGine DSL integration
```

## WASM Exported Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `physics_init` | `() → void` | Create world + scene (idempotent) |
| `physics_step` | `(f32 dt) → void` | Advance simulation |
| `physics_get_transforms` | `() → i32` | Pack transforms, return float count |
| `physics_get_transform_ptr` | `() → i32` | Get pointer to transform buffer |
| `physics_get_body_count` | `() → i32` | Number of active bodies |
| `physics_explode` | `(f32 x, f32 y, f32 r, f32 impulse) → void` | Trigger explosion |

### Transform Buffer Layout

Each body outputs 4 floats: `[x, y, cos(angle), sin(angle)]`

```
Body 0: [x₀, y₀, cos₀, sin₀]
Body 1: [x₁, y₁, cos₁, sin₁]
...
Body N: [xₙ, yₙ, cosₙ, sinₙ]
```

## PNGine DSL Integration

See [domino_cascade.pngine](./domino_cascade.pngine) for a complete example.

Key DSL pattern:
```
#wasmCall physicsStep {
  module={ url="domino_cascade.wasm" }
  func=physics_step
  args=[time.delta]
  returns=void
}

#wasmCall physicsTransforms {
  module={ url="domino_cascade.wasm" }
  func=physics_get_transforms
  args=[]
  returns="array<f32, 120>"    // 30 bodies × 4 floats
}
```

## Box2D v3 — Why It Works for WASM

- **Pure C17** — no C++ stdlib, compiles with Zig's bundled clang
- **No source modifications** — `timer.c` has no-op fallback stubs for unknown platforms
- **Tiny output** — estimated ~100-200KB WASM (vs 1.5MB for Rapier)
- **Clean API** — `b2World_Step`, `b2Body_GetPosition` map directly to `#wasmCall`
- **Custom allocator** — `b2SetAllocator()` for WASM memory management

## License

Box2D is MIT licensed. See [external/box2d/LICENSE](../../external/box2d/LICENSE).
