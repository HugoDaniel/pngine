# PNGine Categorical Shader Composer

> A visual shader composition system based on category theory, powered by the lygia shader library

---

## Executive Summary

This document describes **PNGine Composer**, a web application that enables users to create GPU shaders through visual composition of cards. Unlike traditional node-based editors, this system is grounded in **category theory**, providing mathematical guarantees about composition correctness and enabling powerful abstractions like functors, monads, and recursive patterns.

**Core Innovation**: Cards are morphisms in a category. The three-column layout represents the fundamental decomposition of any shader into Domain (where), Structure (what), and Codomain (how it looks). Functor cards wrap entire compositions, enabling tiling, feedback loops, and temporal effects. Combinator cards enable point-free composition.

**Foundation**: The [lygia shader library](https://lygia.xyz) provides 250+ WGSL functions that naturally form categorical morphisms. We build the compositional structure on top.

**Target Users**:
1. **Artists**: Drag cards, see results, no code required
2. **Intermediate**: Use combinators for complex effects
3. **Advanced**: Save compositions as cards, build libraries

---

## Table of Contents

1. [Theoretical Foundation](#1-theoretical-foundation)
2. [Lygia as Categorical Primitives](#2-lygia-as-categorical-primitives)
3. [The Three-Column Model](#3-the-three-column-model)
4. [Card Taxonomy](#4-card-taxonomy)
5. [Type System](#5-type-system)
6. [Combinator Cards](#6-combinator-cards)
7. [Functor Wrappers](#7-functor-wrappers)
8. [Composition as Cards](#8-composition-as-cards)
9. [Code Generation](#9-code-generation)
10. [Data Structures](#10-data-structures)
11. [User Interface](#11-user-interface)
12. [Implementation Phases](#12-implementation-phases)
13. [Examples](#13-examples)
14. [Future Extensions](#14-future-extensions)

---

## 1. Theoretical Foundation

### 1.1 Why Category Theory?

Category theory provides:

1. **Compositionality**: If A→B and B→C are valid, then A→C is valid
2. **Type Safety**: Compositions that don't type-check are rejected
3. **Abstraction**: Functors transform entire compositions uniformly
4. **Laws**: Guarantees about behavior (identity, associativity)
5. **Vocabulary**: Precise language for composition patterns

### 1.2 The Shader Category

Every fragment shader lives in a category:

```
Category: Shader
─────────────────

Objects (Types):
  UV      = vec2    (texture coordinates, 0-1 range)
  Value   = float   (scalar value, typically 0-1)
  Color   = vec3    (RGB color)
  RGBA    = vec4    (RGB + alpha)
  Tex     = texture (sampler2D)

Morphisms (Functions):
  SpaceTransform : UV → UV        (coordinate transformations)
  Generator      : UV → Value     (pattern generation)
  Palette        : Value → Color  (value-to-color mapping)
  ColorEffect    : Color → Color  (color modifications)
  Sampler        : (Tex, UV) → Color

Identity:
  id_UV    : UV → UV       = λuv. uv
  id_Value : Value → Value = λv. v
  id_Color : Color → Color = λc. c

Composition:
  (f : A → B) ∘ (g : B → C) = (g ∘ f) : A → C
```

### 1.3 Functors in Shader Context

A **functor** F maps:
- Objects to objects: F(A) → F(A)
- Morphisms to morphisms: F(f : A → B) → F(f) : F(A) → F(B)

Preserving:
- Identity: F(id) = id
- Composition: F(g ∘ f) = F(g) ∘ F(f)

**Shader Functors**:

| Functor | Action on Objects | Action on Morphisms |
|---------|-------------------|---------------------|
| **Tile** | UV → UV (tiled) | Applies f to tiled UV |
| **Mirror** | UV → UV (mirrored) | Applies f to mirrored UV |
| **Rotate** | UV → UV (rotated) | Applies f to rotated UV |
| **Feedback** | A → (A, Texture) | Threads previous frame |
| **Temporal** | A → (Time → A) | Makes output time-varying |

### 1.4 Monads for Effects

A **monad** M provides:
- `return : A → M A` (inject value into context)
- `bind : M A → (A → M B) → M B` (sequence computations)

**Shader Monads**:

| Monad | Context | return | bind |
|-------|---------|--------|------|
| **Reader UV** | Access to coordinates | Constant function | Pass UV through |
| **Reader Time** | Access to time | Constant function | Pass time through |
| **State Texture** | Previous frame | No dependency | Thread texture |
| **Random** | Seeded randomness | Deterministic | Chain seeds |

### 1.5 The Fundamental Insight

Every fragment shader is already monadic:

```haskell
type Shader a = ReaderT (UV, Time) (State Texture) a

-- Equivalent to:
type Shader a = UV → Time → Texture → (a, Texture)

-- For non-feedback shaders (most common):
type SimpleShader a = UV → Time → a
```

The three-column layout visualizes this monad structure.

---

## 2. Lygia as Categorical Primitives

### 2.1 Lygia Overview

[Lygia](https://lygia.xyz) is the largest cross-platform shader library:
- **254 WGSL functions** (WebGPU-ready)
- **656 GLSL functions** (reference)
- Categories: generative, sdf, color, space, filter, math
- MIT-style license (Prosperity + Patron)
- Self-contained functions (each includes dependencies)

### 2.2 Lygia Functions as Morphisms

Lygia functions naturally partition into categorical morphisms:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    LYGIA MORPHISM CLASSIFICATION                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  SPACE TRANSFORMS (UV → UV)                                             │
│  lygia/space/                                                           │
│  ├── tile(uv, scale) → uv          Repeat pattern                       │
│  ├── rotate(uv, angle) → uv        Rotate around center                 │
│  ├── scale(uv, factor) → uv        Zoom in/out                          │
│  ├── mirror(uv, axis) → uv         Reflect across axis                  │
│  ├── ratio(uv, res) → uv           Aspect ratio correction              │
│  └── ...                                                                │
│                                                                         │
│  GENERATORS (UV → Value)                                                │
│  lygia/generative/                                                      │
│  ├── cnoise(uv) → float            Classic Perlin noise                 │
│  ├── snoise(uv) → float            Simplex noise                        │
│  ├── voronoi(uv) → vec3            Voronoi (distance, cell, edge)       │
│  ├── fbm(uv, octaves) → float      Fractal Brownian motion              │
│  ├── worley(uv) → float            Worley/cellular noise                │
│  ├── curl(uv) → vec2               Curl noise                           │
│  ├── random(uv) → float            Pseudo-random                        │
│  └── ...                                                                │
│                                                                         │
│  lygia/sdf/                                                             │
│  ├── circleSDF(uv, r) → float      Circle distance field                │
│  ├── rectSDF(uv, size) → float     Rectangle distance field             │
│  ├── starSDF(uv, n, r) → float     Star distance field                  │
│  ├── polySDF(uv, n) → float        Regular polygon                      │
│  ├── lineSDF(uv, a, b) → float     Line segment                         │
│  ├── heartSDF(uv) → float          Heart shape                          │
│  └── ...                                                                │
│                                                                         │
│  PALETTES (Value → Color)                                               │
│  lygia/color/palette/                                                   │
│  ├── spectral(t) → vec3            Rainbow spectrum                     │
│  ├── heatmap(t) → vec3             Cold to hot                          │
│  ├── viridis(t) → vec3             Scientific (blue-green-yellow)       │
│  ├── magma(t) → vec3               Dark to bright (volcanic)            │
│  ├── inferno(t) → vec3             Black-red-yellow-white               │
│  ├── plasma(t) → vec3              Purple-pink-orange-yellow            │
│  └── ...                                                                │
│                                                                         │
│  COLOR EFFECTS (Color → Color)                                          │
│  lygia/color/                                                           │
│  ├── brightness(c, amount) → vec3  Adjust brightness                    │
│  ├── contrast(c, amount) → vec3    Adjust contrast                      │
│  ├── saturation(c, amount) → vec3  Adjust saturation                    │
│  ├── hueShift(c, angle) → vec3     Rotate hue                           │
│  ├── blend*(a, b, mode) → vec3     Blend modes                          │
│  └── ...                                                                │
│                                                                         │
│  lygia/filter/                                                          │
│  ├── gaussianBlur(tex, uv, r) → vec3  Gaussian blur                     │
│  ├── sharpen(tex, uv) → vec3          Sharpen                           │
│  ├── edge(tex, uv) → vec3             Edge detection                    │
│  └── ...                                                                │
│                                                                         │
│  UTILITIES (Various)                                                    │
│  lygia/color/                                                           │
│  ├── luma(c) → float               Luminance (Color → Value)            │
│  ├── desaturate(c, amount) → vec3  Desaturate                           │
│  └── ...                                                                │
│                                                                         │
│  lygia/math/                                                            │
│  ├── mod289(x) → x                 Hash helper                          │
│  ├── permute(x) → x                Permutation                          │
│  └── ...                           (internal, auto-included)            │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.3 Morphism Composition Table

Which morphisms can compose with which:

```
                    TO →
                    UV      Value   Color   RGBA
         ┌─────────────────────────────────────────┐
         │ UV      │  ✓     │  ✓    │  ✓   │  ✓   │
FROM ↓   │ Value   │  ✗     │  ✓    │  ✓   │  ✓   │
         │ Color   │  ✗     │  ✓    │  ✓   │  ✓   │
         │ RGBA    │  ✗     │  ✓    │  ✓   │  ✓   │
         └─────────────────────────────────────────┘

Valid compositions:
  UV → UV → Value → Color → RGBA  (standard pipeline)
  UV → UV → UV → Value            (multiple transforms)
  UV → Value → Value → Color      (value processing)
  Color → Value → Color           (via luma, back to color)
```

### 2.4 Lygia Inlining Strategy

Lygia uses `#include` directives. For web, we inline at build time:

```typescript
// Build-time: Create a map of all lygia functions
const lygiaFunctions: Map<string, string> = new Map();

// Example entry
lygiaFunctions.set('generative/cnoise', `
  // From lygia/generative/cnoise.wgsl
  fn mod289_2(x: vec2f) -> vec2f { return x - floor(x * (1.0 / 289.0)) * 289.0; }
  fn mod289_3(x: vec3f) -> vec3f { return x - floor(x * (1.0 / 289.0)) * 289.0; }
  fn permute3(x: vec3f) -> vec3f { return mod289_3(((x * 34.0) + 1.0) * x); }

  fn cnoise(P: vec2f) -> f32 {
    // ... full implementation
  }
`);

// At composition time: collect unique imports
function collectImports(cards: Card[]): string[] {
  const imports = new Set<string>();
  for (const card of cards) {
    for (const imp of card.lygiaImports) {
      imports.add(imp);
    }
  }
  return [...imports];
}

// Generate WGSL with inlined functions
function inlineLygia(imports: string[]): string {
  return imports.map(imp => lygiaFunctions.get(imp) ?? '').join('\n\n');
}
```

---

## 3. The Three-Column Model

### 3.1 Categorical Interpretation

The three columns represent the **fundamental decomposition** of any shader:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│   DOMAIN              STRUCTURE              CODOMAIN                   │
│   (Reader UV)         (Generator)            (Representable)            │
│                                                                         │
│   "Where to look"     "What's there"         "How it looks"             │
│                                                                         │
│   UV → UV             UV → Value             Value/Color → Color        │
│                                                                         │
│   Endofunctor on      Morphism from          Representable functor      │
│   UV category         UV to Value            (determines appearance)    │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   SPACE TRANSFORMS    GENERATORS             COLORIZERS                 │
│                                                                         │
│   ┌─────────────┐     ┌─────────────────┐    ┌─────────────────┐       │
│   │ tile        │     │ noise           │    │ palette         │       │
│   │ rotate      │     │ voronoi         │    │ brightness      │       │
│   │ scale       │     │ fbm             │    │ contrast        │       │
│   │ mirror      │     │ sdf shapes      │    │ saturation      │       │
│   │ warp        │     │ gradients       │    │ glow            │       │
│   │ kaleidoscope│     │ patterns        │    │ vignette        │       │
│   └─────────────┘     └─────────────────┘    └─────────────────┘       │
│                                                                         │
│   Category: Space     Category: Gen          Category: Chrom            │
│   Objects: {UV}       Objects: {UV, Value}   Objects: {Value, Color}    │
│   Morphisms: UV→UV    Morphisms: UV→Value    Morphisms: *→Color         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Data Flow

```
Input                    Processing                     Output
─────                    ──────────                     ──────

                    ┌──────────────────────────────────────────┐
                    │                                          │
   UV ─────────────▶│  DOMAIN    ─────▶  STRUCTURE  ─────▶     │
   (coordinates)    │  UV → UV'          UV' → Value           │
                    │                                          │
   Time ───────────▶│  (available to all columns via uniform)  │
   (animation)      │                                          │
                    │                    CODOMAIN              │────▶ Color
   PrevFrame ──────▶│                    Value → Color         │      (output)
   (feedback)       │                    Color → Color         │
                    │                                          │
                    └──────────────────────────────────────────┘
```

### 3.3 Column Composition Rules

**Within columns**: Cards compose vertically (top to bottom)

```
Column: DOMAIN
┌─────────────┐
│ tile 3×3    │  UV → UV
└──────┬──────┘
       │
┌──────▼──────┐
│ rotate 45°  │  UV → UV
└──────┬──────┘
       │
┌──────▼──────┐
│ mirror X    │  UV → UV
└─────────────┘

Result: tile >>> rotate >>> mirror : UV → UV
```

**Across columns**: Natural transformations (handled automatically)

```
DOMAIN           η         STRUCTURE         ε         CODOMAIN
UV → UV    ───────────▶    UV → Value   ───────────▶   Value → Color

The natural transformations η and ε are implicit:
  η: "use the transformed UV to generate a value"
  ε: "use the generated value to produce a color"
```

### 3.4 Visual Layout

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  ╔═══════════════════════════════════════════════════════════════════════════╗ │
│  ║  FUNCTOR WRAPPER: [None ▾]  [🔲 Tile] [🪞 Mirror] [🔄 Feedback] [⏱ Time]   ║ │
│  ╚═══════════════════════════════════════════════════════════════════════════╝ │
│                                                                                 │
│  ┌─────────────────┐  ┌───────────────────────┐  ┌─────────────────┐          │
│  │     DOMAIN      │  │       STRUCTURE       │  │     CODOMAIN    │          │
│  │    (UV → UV)    │  │     (UV → Value)      │  │  (* → Color)    │          │
│  │                 │  │                       │  │                 │          │
│  │  ┌───────────┐  │  │  ┌─────────────────┐  │  │  ┌───────────┐  │          │
│  │  │ 🔲 Tile   │  │  │  │                 │  │  │  │ 🌈 Spectr │  │          │
│  │  │ 3 × 3     │  │  │  │   ┌─────────┐   │  │  │  │ offset: 0 │  │          │
│  │  └─────┬─────┘  │  │  │   │ 🌊 Noise │   │  │  │  └─────┬─────┘  │          │
│  │        │        │  │  │   │ scale:4 │   │  │  │        │        │          │
│  │  ┌─────▼─────┐  │  │  │   └────┬────┘   │  │  │  ┌─────▼─────┐  │          │
│  │  │ 🔄 Rotate │  │  │  │   ┌────▼────┐   │  │  │  │ ✨ Glow   │  │          │
│  │  │ speed:0.5 │──┼──┼─▶│   │ ⊗ BLEND │   │──┼──┼─▶│ int: 0.5  │  │          │
│  │  └─────┬─────┘  │  │  │   │ ┌─┬───┐ │   │  │  │  └─────┬─────┘  │          │
│  │        │        │  │  │   │ │A│ B │ │   │  │  │        │        │          │
│  │  ┌─────▼─────┐  │  │  │   │ └─┴───┘ │   │  │  │  ┌─────▼─────┐  │          │
│  │  │ 🌀 Warp   │  │  │  │   └─────────┘   │  │  │  │ 🎬 Vignet │  │          │
│  │  │ amt: 0.1  │  │  │  │                 │  │  │  │ str: 0.4  │  │          │
│  │  └───────────┘  │  │  └─────────────────┘  │  │  └───────────┘  │          │
│  │                 │  │                       │  │                 │          │
│  │  [+ Add Card]   │  │     [+ Add Card]      │  │  [+ Add Card]   │          │
│  └─────────────────┘  └───────────────────────┘  └─────────────────┘          │
│                                                                                 │
│                         ┌───────────────────┐                                  │
│                         │                   │                                  │
│                         │   LIVE PREVIEW    │                                  │
│                         │                   │                                  │
│                         │    ┌─────────┐    │                                  │
│                         │    │         │    │                                  │
│                         │    │ WebGPU  │    │                                  │
│                         │    │ Canvas  │    │                                  │
│                         │    │         │    │                                  │
│                         │    └─────────┘    │                                  │
│                         │                   │                                  │
│                         │   Size: 2.1 KB    │                                  │
│                         └───────────────────┘                                  │
│                                                                                 │
├─────────────────────────────────────────────────────────────────────────────────┤
│  COMBINATORS                                                                    │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐              │
│  │  ▷   │ │  ⊗   │ │  ⊕   │ │  🔄  │ │  ⇑   │ │  λ   │ │  📦  │              │
│  │ pipe │ │ prod │ │ sum  │ │ fix  │ │ lift │ │ func │ │ save │              │
│  │ f>>>g│ │ f×g  │ │ f+g  │ │ μX.F │ │ F(f) │ │ a→b  │ │      │              │
│  └──────┘ └──────┘ └──────┘ └──────┘ └──────┘ └──────┘ └──────┘              │
│                                                                                 │
├─────────────────────────────────────────────────────────────────────────────────┤
│  PRIMITIVE CARDS (drag to columns)                                              │
│                                                                                 │
│  [All ▾] [Space] [Generative] [SDF] [Palette] [Effect] [Saved]                 │
│                                                                                 │
│  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐    │
│  │ 🔲  │ │ 🔄  │ │ 🌊  │ │ 🔷  │ │ ⭕  │ │ 🌈  │ │ 🔥  │ │ ✨  │ │ 🎬  │    │
│  │tile │ │rot  │ │noise│ │voron│ │circl│ │spectr│ │heat │ │glow │ │vign │    │
│  └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘    │
│                                                                                 │
├─────────────────────────────────────────────────────────────────────────────────┤
│  [View Code]  [Copy DSL]  [Download PNG]  [Share Link]  [Save as Card]         │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Card Taxonomy

### 4.1 Card Kinds

```typescript
type CardKind =
  | 'primitive'     // Wraps a single lygia function
  | 'composite'     // Combines multiple primitives (non-higher-order)
  | 'combinator'    // Higher-order: takes cards as input
  | 'functor'       // Wraps entire compositions
  | 'saved'         // User-saved composition as card
  ;
```

### 4.2 Primitive Cards

Direct wrappers around lygia functions:

#### Space Primitives (UV → UV)

| Card | Lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Tile** | `space/tile` | countX, countY | Repeat pattern in grid |
| **Rotate** | `space/rotate` | angle, speed, centerX, centerY | Rotate around point |
| **Scale** | `space/scale` | scaleX, scaleY, centerX, centerY | Zoom in/out |
| **Mirror** | `space/mirror` | axisX, axisY | Reflect across axis |
| **Ratio** | `space/ratio` | — | Fix aspect ratio |

#### Generative Primitives (UV → Value)

| Card | Lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Perlin** | `generative/cnoise` | scale, speed, offsetX, offsetY | Classic smooth noise |
| **Simplex** | `generative/snoise` | scale, speed | Faster noise |
| **Voronoi** | `generative/voronoi` | scale, jitter | Cell pattern |
| **FBM** | `generative/fbm` | scale, octaves, gain, lacunarity | Fractal noise |
| **Worley** | `generative/worley` | scale, jitter | Cellular noise |
| **Random** | `generative/random` | seed | White noise |

#### SDF Primitives (UV → Value)

| Card | Lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Circle** | `sdf/circleSDF` | radius, centerX, centerY, softness | Round shape |
| **Rectangle** | `sdf/rectSDF` | width, height, centerX, centerY | Box shape |
| **Star** | `sdf/starSDF` | points, innerRadius, outerRadius | Star shape |
| **Polygon** | `sdf/polySDF` | sides, size | Regular polygon |
| **Line** | `sdf/lineSDF` | x1, y1, x2, y2, width | Line segment |
| **Heart** | `sdf/heartSDF` | size | Heart shape |

#### Palette Primitives (Value → Color)

| Card | Lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Rainbow** | `color/palette/spectral` | offset, cycles | Full spectrum |
| **Heatmap** | `color/palette/heatmap` | offset | Cold to hot |
| **Viridis** | `color/palette/viridis` | offset | Scientific |
| **Magma** | `color/palette/magma` | offset | Volcanic |
| **Plasma** | `color/palette/plasma` | offset | Purple-yellow |
| **Grayscale** | — | invert | Black to white |
| **Duotone** | — | color1, color2 | Two-color gradient |

#### Effect Primitives (Color → Color)

| Card | Lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Brightness** | `color/brightness` | amount | Lighten/darken |
| **Contrast** | `color/contrast` | amount | Adjust contrast |
| **Saturation** | `color/saturation` | amount | Color intensity |
| **Hue Shift** | `color/hueShift` | degrees | Rotate hue |
| **Glow** | — | intensity, threshold | Bloom effect |
| **Vignette** | — | strength, softness | Dark edges |

### 4.3 Composite Cards

Pre-built combinations that aren't higher-order:

| Card | Composition | Description |
|------|-------------|-------------|
| **Tiled Noise** | tile >>> noise | Repeated noise pattern |
| **Masked Circle** | noise ⊗ circle | Noise inside circle |
| **Plasma** | fbm >>> rainbow | Classic plasma effect |
| **Lava** | (fbm ⊗ warp) >>> heatmap | Flowing lava |

### 4.4 Card Parameter Types

```typescript
type ParamType =
  | 'float'     // Slider: 0.0 - 1.0 (or custom range)
  | 'int'       // Integer slider
  | 'vec2'      // Two floats (x, y)
  | 'vec3'      // Three floats (x, y, z) or color picker
  | 'color'     // RGB color picker
  | 'bool'      // Toggle
  | 'select'    // Dropdown
  | 'angle'     // Angle picker (0-360 or radians)
  ;

interface CardParam {
  name: string;           // Internal name: 'scale'
  label: string;          // Display name: 'Scale'
  type: ParamType;
  default: ParamValue;

  // For numeric types
  range?: [number, number];
  step?: number;

  // For select type
  options?: { value: string; label: string }[];

  // UI hints
  group?: string;         // Group related params
  advanced?: boolean;     // Hide in simple mode

  // Animation
  animatable?: boolean;   // Can be driven by time
  animationExpr?: string; // e.g., 'sin(time * {speed})'
}
```

---

## 5. Type System

### 5.1 Shader Types

```typescript
// Core types in the shader category
type ShaderType = 'uv' | 'value' | 'color' | 'rgba' | 'texture';

// Type aliases for clarity
type UV = 'uv';           // vec2, 0-1 range
type Value = 'value';     // float, typically 0-1
type Color = 'color';     // vec3, RGB
type RGBA = 'rgba';       // vec4, RGBA
type Texture = 'texture'; // sampler2D

// Morphism signature
interface MorphismType {
  input: ShaderType | 'any' | ShaderType[];
  output: ShaderType;
}
```

### 5.2 Card Type Signatures

```typescript
interface TypedCard {
  // ... other fields
  signature: MorphismType;
}

// Examples:
const tileCard: TypedCard = {
  signature: { input: 'uv', output: 'uv' },
};

const noiseCard: TypedCard = {
  signature: { input: 'uv', output: 'value' },
};

const rainbowCard: TypedCard = {
  signature: { input: 'value', output: 'color' },
};

const glowCard: TypedCard = {
  signature: { input: 'color', output: 'color' },
};

// Polymorphic card (works on multiple types)
const brightnessCard: TypedCard = {
  signature: { input: ['value', 'color'], output: 'same' }, // Output matches input
};
```

### 5.3 Type Checking Composition

```typescript
function canCompose(a: TypedCard, b: TypedCard): boolean {
  // a's output must match b's input
  const aOut = a.signature.output;
  const bIn = b.signature.input;

  if (bIn === 'any') return true;
  if (Array.isArray(bIn)) return bIn.includes(aOut);
  return aOut === bIn;
}

function composeTypes(a: MorphismType, b: MorphismType): MorphismType | null {
  if (!canCompose({ signature: a }, { signature: b })) return null;

  return {
    input: a.input,
    output: b.output === 'same' ? a.output : b.output,
  };
}

// Type inference for columns
function inferColumnType(cards: TypedCard[]): MorphismType | null {
  if (cards.length === 0) return { input: 'any', output: 'any' };

  let current = cards[0].signature;
  for (let i = 1; i < cards.length; i++) {
    const next = composeTypes(current, cards[i].signature);
    if (!next) return null; // Type error!
    current = next;
  }
  return current;
}
```

### 5.4 Column Type Constraints

```typescript
// Each column has expected input/output types
const columnConstraints = {
  domain: {
    expectedInput: 'uv',
    expectedOutput: 'uv',
    accepts: (sig: MorphismType) => sig.input === 'uv' && sig.output === 'uv',
  },
  structure: {
    expectedInput: 'uv',
    expectedOutput: 'value',
    accepts: (sig: MorphismType) => sig.input === 'uv' && sig.output === 'value',
  },
  codomain: {
    expectedInput: ['value', 'color'],
    expectedOutput: 'color',
    accepts: (sig: MorphismType) =>
      ['value', 'color'].includes(sig.input as string) && sig.output === 'color',
  },
};
```

### 5.5 Automatic Type Coercion

When types don't match exactly, insert coercion cards:

```typescript
const coercions: Map<string, Card> = new Map([
  // Value to Color (grayscale)
  ['value→color', {
    id: 'coerce-value-color',
    wgsl: 'vec3f({input})',
    signature: { input: 'value', output: 'color' },
  }],

  // Color to Value (luminance)
  ['color→value', {
    id: 'coerce-color-value',
    wgsl: 'dot({input}, vec3f(0.299, 0.587, 0.114))',
    signature: { input: 'color', output: 'value' },
  }],

  // Color to RGBA
  ['color→rgba', {
    id: 'coerce-color-rgba',
    wgsl: 'vec4f({input}, 1.0)',
    signature: { input: 'color', output: 'rgba' },
  }],
]);

function insertCoercion(from: ShaderType, to: ShaderType): Card | null {
  return coercions.get(`${from}→${to}`) ?? null;
}
```

---

## 6. Combinator Cards

Combinators are **higher-order cards** that take other cards as inputs.

### 6.1 Pipe (>>>): Sequential Composition

```typescript
interface PipeCombinator {
  kind: 'combinator';
  combinator: 'pipe';
  slots: {
    first: CardSlot;   // f : A → B
    second: CardSlot;  // g : B → C
  };
  // Result: A → C
}

// Type rule:
// Γ ⊢ f : A → B    Γ ⊢ g : B → C
// ─────────────────────────────────
// Γ ⊢ (f >>> g) : A → C
```

**Visual**:

```
┌─────────────────────────────────┐
│ ▷ Pipe (>>>)                    │
│                                 │
│  ┌─────────┐     ┌─────────┐   │
│  │ First   │ ──▶ │ Second  │   │
│  │ (A → B) │     │ (B → C) │   │
│  └─────────┘     └─────────┘   │
│                                 │
│  Result: A → C                  │
└─────────────────────────────────┘
```

**WGSL Generation**:

```typescript
function compilePipe(first: CompiledCard, second: CompiledCard): string {
  // second.expr with {input} replaced by first.expr
  return second.expr.replace('{input}', `(${first.expr})`);
}
```

### 6.2 Product (⊗): Parallel Composition

```typescript
interface ProductCombinator {
  kind: 'combinator';
  combinator: 'product';
  slots: {
    left: CardSlot;    // f : A → B
    right: CardSlot;   // g : A → B
  };
  merge: 'add' | 'multiply' | 'max' | 'min' | 'average' | 'mix';
  mixFactor?: number;  // For 'mix' mode
  // Result: A → B (same type as inputs)
}

// Type rule:
// Γ ⊢ f : A → B    Γ ⊢ g : A → B
// ─────────────────────────────────
// Γ ⊢ (f ⊗ g) : A → B
```

**Visual**:

```
┌─────────────────────────────────┐
│ ⊗ Product                       │
│                                 │
│      ┌─────────┐                │
│   ┌──│ Left    │──┐             │
│   │  │ (A → B) │  │             │
│ ──┤  └─────────┘  ├──▶ [merge]  │
│   │  ┌─────────┐  │             │
│   └──│ Right   │──┘             │
│      │ (A → B) │                │
│      └─────────┘                │
│                                 │
│  Merge: [multiply ▾]            │
│  Result: A → B                  │
└─────────────────────────────────┘
```

**WGSL Generation**:

```typescript
function compileProduct(left: CompiledCard, right: CompiledCard, merge: string): string {
  const l = left.expr;
  const r = right.expr;

  switch (merge) {
    case 'add':      return `clamp(${l} + ${r}, 0.0, 1.0)`;
    case 'multiply': return `(${l} * ${r})`;
    case 'max':      return `max(${l}, ${r})`;
    case 'min':      return `min(${l}, ${r})`;
    case 'average':  return `((${l} + ${r}) * 0.5)`;
    case 'mix':      return `mix(${l}, ${r}, ${mixFactor})`;
  }
}
```

### 6.3 Sum (⊕): Choice Composition

```typescript
interface SumCombinator {
  kind: 'combinator';
  combinator: 'sum';
  slots: {
    left: CardSlot;     // f : A → B
    right: CardSlot;    // g : A → B
    selector: CardSlot; // s : A → Value (0 = left, 1 = right)
  };
  // Result: A → B
}

// Type rule:
// Γ ⊢ f : A → B    Γ ⊢ g : A → B    Γ ⊢ s : A → Value
// ──────────────────────────────────────────────────────
// Γ ⊢ (f ⊕_s g) : A → B
```

**Visual**:

```
┌─────────────────────────────────┐
│ ⊕ Sum (Choice)                  │
│                                 │
│         ┌──────────┐            │
│         │ Selector │            │
│         │ (A→Value)│            │
│         └────┬─────┘            │
│              │ (0-1)            │
│        ┌─────┴─────┐            │
│   ┌────▼────┐ ┌────▼────┐       │
│   │ Left    │ │ Right   │       │
│   │ (A → B) │ │ (A → B) │       │
│   └─────────┘ └─────────┘       │
│                                 │
│  Result: A → B                  │
│  (mix based on selector)        │
└─────────────────────────────────┘
```

**WGSL Generation**:

```typescript
function compileSum(left: CompiledCard, right: CompiledCard, selector: CompiledCard): string {
  return `mix(${left.expr}, ${right.expr}, ${selector.expr})`;
}
```

### 6.4 Fix (μ): Recursive Composition

```typescript
interface FixCombinator {
  kind: 'combinator';
  combinator: 'fix';
  slots: {
    body: CardSlot;  // f : (A, A) → A (has {self} placeholder)
  };
  maxIterations: number;  // Bounded recursion
  // Result: A → A
}

// Type rule (simplified):
// Γ, self : A ⊢ f : A → A
// ─────────────────────────
// Γ ⊢ fix(f) : A → A
```

**Visual**:

```
┌─────────────────────────────────┐
│ 🔄 Fix (Recursion)              │
│                                 │
│  ┌───────────────────────────┐  │
│  │ Body (uses {self})        │  │
│  │                           │  │
│  │  scale(0.5) >>>           │  │
│  │  rotate(30°) >>>          │  │
│  │  blend({self}, 0.5)       │  │
│  │         ▲                 │  │
│  │         │                 │  │
│  │    ┌────┴────┐            │  │
│  │    │  SELF   │◀───────────┼──┤
│  │    │(recurse)│            │  │
│  │    └─────────┘            │  │
│  └───────────────────────────┘  │
│                                 │
│  Iterations: [5 ▾]              │
│  Result: Fractal pattern        │
└─────────────────────────────────┘
```

**WGSL Generation** (loop unrolling):

```typescript
function compileFix(body: CompiledCard, maxIterations: number): string {
  let expr = '0.0';  // Base case (or configurable)

  for (let i = 0; i < maxIterations; i++) {
    expr = body.expr.replace(/{self}/g, `(${expr})`);
  }

  return expr;
}

// Example: fractal noise
// Body: mix(noise(uv * 0.5), {self}, 0.5)
// Iteration 0: 0.0
// Iteration 1: mix(noise(uv * 0.5), 0.0, 0.5)
// Iteration 2: mix(noise(uv * 0.5), mix(noise(uv * 0.5), 0.0, 0.5), 0.5)
// ... creates fractal layering
```

### 6.5 Lift (⇑): Functor Application

```typescript
interface LiftCombinator {
  kind: 'combinator';
  combinator: 'lift';
  slots: {
    functor: FunctorSlot;  // F
    inner: CardSlot;       // f : A → B
  };
  // Result: F(f) : F(A) → F(B)
}

// Type rule:
// Γ ⊢ F : Functor    Γ ⊢ f : A → B
// ──────────────────────────────────
// Γ ⊢ lift(F, f) : F(A) → F(B)
```

**Visual**:

```
┌─────────────────────────────────┐
│ ⇑ Lift                          │
│                                 │
│  Functor: [🔲 Tile 3×3 ▾]       │
│                                 │
│  ╔═══════════════════════════╗  │
│  ║  ┌─────────────────────┐  ║  │
│  ║  │ Inner Card          │  ║  │
│  ║  │                     │  ║  │
│  ║  │  noise >>> rainbow  │  ║  │
│  ║  │                     │  ║  │
│  ║  └─────────────────────┘  ║  │
│  ╚═══════════════════════════╝  │
│                                 │
│  Result: Tiled(noise>>>rainbow) │
└─────────────────────────────────┘
```

**WGSL Generation**:

```typescript
function compileLift(functor: Functor, inner: CompiledCard): string {
  // Functor modifies the context (e.g., UV) before applying inner
  return functor.wrapExpr(inner.expr);
}

// Example: Tile functor
const tileFunctor = {
  wrapExpr: (inner: string) => `
    let tiledUV = fract(uv * vec2f(${countX}, ${countY}));
    ${inner.replace(/\buv\b/g, 'tiledUV')}
  `,
};
```

### 6.6 Lambda (λ): Abstraction (Advanced)

```typescript
interface LambdaCombinator {
  kind: 'combinator';
  combinator: 'lambda';
  slots: {
    body: CardSlot;  // Expression with {param} placeholder
  };
  paramName: string;
  paramType: ShaderType;
  // Result: A function card that can be applied
}
```

This enables creating custom cards inline without saving.

---

## 7. Functor Wrappers

Functor wrappers apply to **entire compositions**, not individual cards.

### 7.1 Tile Functor

Repeats the entire composition in a grid.

```typescript
const TileFunctor: FunctorDefinition = {
  id: 'tile-functor',
  name: 'Tile',
  icon: '🔲',

  params: [
    { name: 'countX', type: 'float', default: 3, range: [1, 10] },
    { name: 'countY', type: 'float', default: 3, range: [1, 10] },
  ],

  // How it modifies UV for the inner composition
  uvTransform: 'fract(uv * vec2f({countX}, {countY}))',

  // Optional: modify output too
  outputTransform: null,

  // Functor laws hold because:
  // - Tile(id) = id on the tiled domain ✓
  // - Tile(f ∘ g) = Tile(f) ∘ Tile(g) ✓ (both see same tiled UV)
};
```

**Generated WGSL**:

```wgsl
@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  var uv = pos.xy / resolution;

  // Tile functor: modify UV before inner composition
  uv = fract(uv * vec2f(3.0, 3.0));

  // Inner composition uses tiled UV
  let value = noise(uv * 4.0);
  let color = spectral(value);

  return vec4f(color, 1.0);
}
```

### 7.2 Mirror Functor

Reflects the composition across axes.

```typescript
const MirrorFunctor: FunctorDefinition = {
  id: 'mirror-functor',
  name: 'Mirror',
  icon: '🪞',

  params: [
    { name: 'axisX', type: 'bool', default: true },
    { name: 'axisY', type: 'bool', default: false },
  ],

  uvTransform: `
    var mirroredUV = uv;
    if ({axisX}) { mirroredUV.x = abs(mirroredUV.x * 2.0 - 1.0); }
    if ({axisY}) { mirroredUV.y = abs(mirroredUV.y * 2.0 - 1.0); }
    mirroredUV
  `,
};
```

### 7.3 Feedback Functor (Monad)

Threads the previous frame through the composition.

```typescript
const FeedbackFunctor: FunctorDefinition = {
  id: 'feedback-functor',
  name: 'Feedback',
  icon: '🔄',
  isMonad: true,  // Has return and bind

  params: [
    { name: 'persistence', type: 'float', default: 0.95, range: [0, 1] },
    { name: 'fadeColor', type: 'color', default: [0, 0, 0] },
  ],

  // Requires additional resources
  requires: {
    feedbackTexture: true,  // Previous frame
    feedbackSampler: true,
  },

  // Before inner composition
  setup: `
    let prevColor = textureSample(feedbackTex, feedbackSampler, uv).rgb;
  `,

  // After inner composition
  outputTransform: `
    mix({output}, prevColor, {persistence})
  `,

  // Monad laws:
  // return: λx. x (no feedback dependency)
  // bind: thread prevColor through composition
};
```

**Generated WGSL**:

```wgsl
@group(0) @binding(1) var feedbackTex: texture_2d<f32>;
@group(0) @binding(2) var feedbackSampler: sampler;

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  var uv = pos.xy / resolution;

  // Feedback functor: sample previous frame
  let prevColor = textureSample(feedbackTex, feedbackSampler, uv).rgb;

  // Inner composition
  let value = noise(uv * 4.0);
  let color = spectral(value);

  // Blend with previous
  let result = mix(color, prevColor, 0.95);

  return vec4f(result, 1.0);
}
```

### 7.4 Temporal Functor

Makes parameters time-varying with easing functions.

```typescript
const TemporalFunctor: FunctorDefinition = {
  id: 'temporal-functor',
  name: 'Temporal',
  icon: '⏱️',

  params: [
    { name: 'speed', type: 'float', default: 1.0, range: [0, 5] },
    { name: 'easing', type: 'select', default: 'linear', options: [
      { value: 'linear', label: 'Linear' },
      { value: 'sineInOut', label: 'Sine In/Out' },
      { value: 'bounceOut', label: 'Bounce' },
      { value: 'elasticOut', label: 'Elastic' },
    ]},
    { name: 'loop', type: 'bool', default: true },
  ],

  // Injects animated time into inner composition
  timeTransform: `
    let t = {loop} ? fract(time * {speed}) : clamp(time * {speed}, 0.0, 1.0);
    let easedTime = {easing}(t);
  `,

  // Inner params can reference 'easedTime'
};
```

### 7.5 Kaleidoscope Functor

Radial symmetry wrapper.

```typescript
const KaleidoscopeFunctor: FunctorDefinition = {
  id: 'kaleidoscope-functor',
  name: 'Kaleidoscope',
  icon: '❄️',

  params: [
    { name: 'segments', type: 'int', default: 6, range: [2, 16] },
    { name: 'rotation', type: 'float', default: 0, range: [0, 360] },
  ],

  uvTransform: `
    let centered = uv - 0.5;
    let angle = atan2(centered.y, centered.x) + radians({rotation});
    let radius = length(centered);
    let segmentAngle = 6.28318 / f32({segments});
    let mirroredAngle = abs(((angle % segmentAngle) + segmentAngle) % segmentAngle - segmentAngle * 0.5);
    vec2f(cos(mirroredAngle), sin(mirroredAngle)) * radius + 0.5
  `,
};
```

### 7.6 Functor Stacking

Multiple functors can be stacked (composed):

```
╔═══════════════════════════════════════════════════════════════════╗
║  🔄 Feedback                                                       ║
║  ╔═══════════════════════════════════════════════════════════════╗║
║  ║  🔲 Tile 3×3                                                  ║║
║  ║  ┌─────────────────────────────────────────────────────────┐  ║║
║  ║  │                 Inner Composition                       │  ║║
║  ║  │                                                         │  ║║
║  ║  │   [Domain] → [Structure] → [Codomain]                   │  ║║
║  ║  │                                                         │  ║║
║  ║  └─────────────────────────────────────────────────────────┘  ║║
║  ╚═══════════════════════════════════════════════════════════════╝║
╚═══════════════════════════════════════════════════════════════════╝

Order matters: Feedback(Tile(inner)) ≠ Tile(Feedback(inner))
```

---

## 8. Composition as Cards

### 8.1 Saving Compositions

Any composition can be saved as a new card:

```typescript
interface SavedCard extends Card {
  kind: 'saved';

  // The frozen composition graph
  composition: CompositionGraph;

  // Which inner parameters are exposed
  exposedParams: ExposedParam[];

  // Computed signature (from composition)
  signature: MorphismType;

  // Metadata
  name: string;
  description: string;
  icon: string;
  author: string;
  tags: string[];

  // Thumbnail (rendered preview)
  thumbnail: string;  // Base64 PNG
}

interface ExposedParam {
  // Path to inner parameter
  path: string;  // e.g., 'structure.cards[0].params.scale'

  // Exposed name and UI
  name: string;
  label: string;

  // Can override range, default, etc.
  overrides?: Partial<CardParam>;
}
```

### 8.2 Composition Graph

```typescript
interface CompositionGraph {
  // Functor wrappers (outer to inner)
  functors: FunctorInstance[];

  // The three columns
  domain: ColumnState;
  structure: ColumnState;
  codomain: ColumnState;

  // Settings
  settings: {
    resolution: { width: number; height: number };
  };
}

interface ColumnState {
  cards: CardInstance[];
}

interface CardInstance {
  cardId: string;           // Reference to card definition
  instanceId: string;       // Unique instance ID
  params: ParamValues;      // Parameter values
  enabled: boolean;
}

interface FunctorInstance {
  functorId: string;
  params: ParamValues;
  enabled: boolean;
}
```

### 8.3 Example: Saving "Lava Flow" Card

```typescript
const lavaFlowCard: SavedCard = {
  kind: 'saved',
  id: 'lava-flow',
  name: 'Lava Flow',
  description: 'Animated flowing lava effect with heat distortion',
  icon: '🌋',
  author: 'PNGine Team',
  tags: ['organic', 'animated', 'fire', 'preset'],

  signature: { input: 'uv', output: 'color' },

  composition: {
    functors: [],

    domain: {
      cards: [
        {
          cardId: 'warp',
          instanceId: 'warp-1',
          params: { amount: 0.15, noiseScale: 2.0, speed: 0.3 },
          enabled: true,
        },
      ],
    },

    structure: {
      cards: [
        {
          cardId: 'product',  // Combinator
          instanceId: 'prod-1',
          params: {
            merge: 'add',
            slots: {
              left: {
                cardId: 'fbm',
                params: { scale: 3.0, octaves: 5, speed: 0.2 },
              },
              right: {
                cardId: 'fbm',
                params: { scale: 6.0, octaves: 3, speed: 0.5 },
              },
            },
          },
          enabled: true,
        },
      ],
    },

    codomain: {
      cards: [
        {
          cardId: 'heatmap',
          instanceId: 'heat-1',
          params: { offset: 0.0 },
          enabled: true,
        },
        {
          cardId: 'glow',
          instanceId: 'glow-1',
          params: { intensity: 0.8, threshold: 0.6 },
          enabled: true,
        },
      ],
    },

    settings: { resolution: { width: 512, height: 512 } },
  },

  exposedParams: [
    {
      path: 'domain.cards[0].params.amount',
      name: 'distortion',
      label: 'Distortion',
      overrides: { range: [0, 0.5], default: 0.15 },
    },
    {
      path: 'structure.cards[0].params.slots.left.params.speed',
      name: 'flowSpeed',
      label: 'Flow Speed',
      overrides: { range: [0, 2], default: 0.2 },
    },
    {
      path: 'codomain.cards[1].params.intensity',
      name: 'glowIntensity',
      label: 'Glow',
      overrides: { range: [0, 2], default: 0.8 },
    },
  ],

  thumbnail: 'data:image/png;base64,...',
};
```

### 8.4 Card Library Management

```typescript
interface CardLibrary {
  // Built-in cards (primitives, composites)
  builtin: Card[];

  // User-saved cards (local storage)
  userCards: SavedCard[];

  // Community cards (fetched from server)
  communityCards: SavedCard[];

  // Operations
  save(composition: CompositionGraph, meta: CardMeta): SavedCard;
  delete(cardId: string): void;
  export(cardId: string): string;  // JSON
  import(json: string): SavedCard;
  publish(cardId: string): Promise<void>;  // To community
}
```

---

## 9. Code Generation

### 9.1 Compilation Pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│                    COMPILATION PIPELINE                             │
│                                                                     │
│  CompositionGraph                                                   │
│        │                                                            │
│        ▼                                                            │
│  ┌─────────────────────┐                                           │
│  │ 1. Type Check       │  Verify all compositions are well-typed   │
│  └──────────┬──────────┘                                           │
│             │                                                       │
│             ▼                                                       │
│  ┌─────────────────────┐                                           │
│  │ 2. Collect Imports  │  Gather all lygia functions needed        │
│  └──────────┬──────────┘                                           │
│             │                                                       │
│             ▼                                                       │
│  ┌─────────────────────┐                                           │
│  │ 3. Build Uniforms   │  Extract all parameters as uniforms       │
│  └──────────┬──────────┘                                           │
│             │                                                       │
│             ▼                                                       │
│  ┌─────────────────────┐                                           │
│  │ 4. Compile Functors │  Generate wrapper code                    │
│  └──────────┬──────────┘                                           │
│             │                                                       │
│             ▼                                                       │
│  ┌─────────────────────┐                                           │
│  │ 5. Compile Columns  │  Generate column expressions              │
│  └──────────┬──────────┘                                           │
│             │                                                       │
│             ▼                                                       │
│  ┌─────────────────────┐                                           │
│  │ 6. Assemble Shader  │  Combine into final WGSL                  │
│  └──────────┬──────────┘                                           │
│             │                                                       │
│             ▼                                                       │
│        WGSL String                                                  │
│             │                                                       │
│             ▼                                                       │
│  ┌─────────────────────┐                                           │
│  │ 7. Generate DSL     │  Create PNGine DSL                        │
│  └──────────┬──────────┘                                           │
│             │                                                       │
│             ▼                                                       │
│        .pngine File                                                 │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 9.2 Type Checking

```typescript
interface TypeCheckResult {
  valid: boolean;
  errors: TypeError[];
  warnings: TypeWarning[];
  inferredTypes: Map<string, MorphismType>;
}

interface TypeError {
  location: CardPath;
  message: string;
  expected: ShaderType;
  actual: ShaderType;
}

function typeCheck(graph: CompositionGraph): TypeCheckResult {
  const errors: TypeError[] = [];
  const warnings: TypeWarning[] = [];
  const inferredTypes = new Map<string, MorphismType>();

  // Check domain column: must be UV → UV
  const domainType = inferColumnType(graph.domain.cards);
  if (domainType && domainType.output !== 'uv') {
    errors.push({
      location: 'domain',
      message: 'Domain column must output UV type',
      expected: 'uv',
      actual: domainType.output,
    });
  }

  // Check structure column: must be UV → Value
  const structureType = inferColumnType(graph.structure.cards);
  if (structureType && structureType.output !== 'value') {
    // Could auto-insert coercion
    warnings.push({
      location: 'structure',
      message: 'Structure column outputs ' + structureType.output + ', will coerce to value',
    });
  }

  // Check codomain column: must output Color
  const codomainType = inferColumnType(graph.codomain.cards);
  if (codomainType && codomainType.output !== 'color') {
    errors.push({
      location: 'codomain',
      message: 'Codomain column must output Color type',
      expected: 'color',
      actual: codomainType.output,
    });
  }

  // Check card-to-card connections within columns
  for (const column of ['domain', 'structure', 'codomain']) {
    const cards = graph[column].cards;
    for (let i = 1; i < cards.length; i++) {
      const prev = getCardSignature(cards[i - 1]);
      const curr = getCardSignature(cards[i]);
      if (!canCompose(prev, curr)) {
        errors.push({
          location: `${column}.cards[${i}]`,
          message: `Cannot compose: ${prev.output} → ${curr.input}`,
          expected: curr.input,
          actual: prev.output,
        });
      }
    }
  }

  return {
    valid: errors.length === 0,
    errors,
    warnings,
    inferredTypes,
  };
}
```

### 9.3 Import Collection

```typescript
function collectImports(graph: CompositionGraph): Set<string> {
  const imports = new Set<string>();

  function processCard(card: CardInstance) {
    const def = getCardDefinition(card.cardId);
    for (const imp of def.lygiaImports ?? []) {
      imports.add(imp);
    }

    // Recurse into combinator slots
    if (def.kind === 'combinator') {
      for (const slot of Object.values(card.params.slots ?? {})) {
        processCard(slot as CardInstance);
      }
    }
  }

  for (const column of [graph.domain, graph.structure, graph.codomain]) {
    for (const card of column.cards) {
      if (card.enabled) {
        processCard(card);
      }
    }
  }

  return imports;
}
```

### 9.4 Uniform Generation

```typescript
interface UniformField {
  name: string;
  type: 'f32' | 'vec2f' | 'vec3f' | 'vec4f' | 'i32';
  path: string;  // For updating from UI
}

function generateUniforms(graph: CompositionGraph): UniformField[] {
  const uniforms: UniformField[] = [
    // Built-in uniforms
    { name: 'time', type: 'f32', path: 'builtin.time' },
    { name: 'resolution', type: 'vec2f', path: 'builtin.resolution' },
  ];

  let uniformIndex = 0;

  function processCard(card: CardInstance, prefix: string) {
    const def = getCardDefinition(card.cardId);
    for (const param of def.params ?? []) {
      uniforms.push({
        name: `u${uniformIndex++}_${param.name}`,
        type: paramTypeToWGSL(param.type),
        path: `${prefix}.${param.name}`,
      });
    }
  }

  // Process all cards...

  return uniforms;
}

function generateUniformStruct(fields: UniformField[]): string {
  const lines = fields.map(f => `  ${f.name}: ${f.type},`);
  return `struct Uniforms {\n${lines.join('\n')}\n}`;
}
```

### 9.5 Column Compilation

```typescript
interface CompiledColumn {
  expr: string;
  inputVar: string;
  outputVar: string;
}

function compileColumn(
  column: ColumnState,
  inputVar: string,
  outputVar: string,
  columnName: string,
): CompiledColumn {
  const enabledCards = column.cards.filter(c => c.enabled);

  if (enabledCards.length === 0) {
    // Identity
    return {
      expr: `let ${outputVar} = ${inputVar};`,
      inputVar,
      outputVar,
    };
  }

  const lines: string[] = [];
  let currentVar = inputVar;

  for (let i = 0; i < enabledCards.length; i++) {
    const card = enabledCards[i];
    const def = getCardDefinition(card.cardId);
    const nextVar = i === enabledCards.length - 1 ? outputVar : `${columnName}_v${i}`;

    const expr = compileCard(card, currentVar);
    lines.push(`let ${nextVar} = ${expr};`);

    currentVar = nextVar;
  }

  return {
    expr: lines.join('\n  '),
    inputVar,
    outputVar,
  };
}

function compileCard(card: CardInstance, inputVar: string): string {
  const def = getCardDefinition(card.cardId);

  // Substitute parameters into template
  let expr = def.wgslTemplate;
  expr = expr.replace('{input}', inputVar);

  for (const [name, value] of Object.entries(card.params)) {
    expr = expr.replace(new RegExp(`\\{${name}\\}`, 'g'), formatValue(value));
  }

  // Handle combinators recursively
  if (def.kind === 'combinator') {
    expr = compileCombinator(card, inputVar);
  }

  return expr;
}
```

### 9.6 Full WGSL Generation

```typescript
function generateWGSL(graph: CompositionGraph): string {
  // 1. Type check
  const typeResult = typeCheck(graph);
  if (!typeResult.valid) {
    throw new CompilationError(typeResult.errors);
  }

  // 2. Collect imports
  const imports = collectImports(graph);
  const lygiaCode = inlineLygia([...imports]);

  // 3. Generate uniforms
  const uniformFields = generateUniforms(graph);
  const uniformStruct = generateUniformStruct(uniformFields);

  // 4. Compile functors (outside-in)
  const functorSetup = compileFunctorSetup(graph.functors);
  const functorWrap = compileFunctorWrap(graph.functors);

  // 5. Compile columns
  const domainCompiled = compileColumn(graph.domain, 'uv', 'domainUV', 'domain');
  const structureCompiled = compileColumn(graph.structure, 'domainUV', 'value', 'structure');
  const codomainCompiled = compileColumn(graph.codomain, 'value', 'color', 'codomain');

  // 6. Assemble
  return `
// ═══════════════════════════════════════════════════════════════════════
// Generated by PNGine Composer
// Using lygia shader library
// ═══════════════════════════════════════════════════════════════════════

// ─── Uniforms ──────────────────────────────────────────────────────────
${uniformStruct}
@group(0) @binding(0) var<uniform> u: Uniforms;

// ─── Lygia Functions ───────────────────────────────────────────────────
${lygiaCode}

// ─── Vertex Shader ─────────────────────────────────────────────────────
@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3));
  return vec4f(pos[i], 0.0, 1.0);
}

// ─── Fragment Shader ───────────────────────────────────────────────────
@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let resolution = u.resolution;
  var uv = pos.xy / resolution;
  uv.y = 1.0 - uv.y;  // Flip Y
  let time = u.time;

  // ─── Functor Setup ───────────────────────────────────────────────────
  ${functorSetup}

  // ─── Domain (UV → UV) ────────────────────────────────────────────────
  ${domainCompiled.expr}

  // ─── Structure (UV → Value) ──────────────────────────────────────────
  ${structureCompiled.expr}

  // ─── Codomain (Value → Color) ────────────────────────────────────────
  ${codomainCompiled.expr}

  // ─── Functor Wrap ────────────────────────────────────────────────────
  ${functorWrap}

  return vec4f(color, 1.0);
}
`;
}
```

### 9.7 PNGine DSL Generation

```typescript
function generatePNGineDSL(graph: CompositionGraph, wgsl: string): string {
  const needsFeedback = graph.functors.some(f => f.functorId === 'feedback-functor');

  let dsl = `// Generated by PNGine Composer

#wgsl shader {
  value=\`${escapeWGSL(wgsl)}\`
}

#buffer uniforms {
  size=64
  usage=[UNIFORM COPY_DST]
}

#queue writeUniforms {
  writeBuffer={
    buffer=uniforms
    bufferOffset=0
    data=pngineInputs
  }
}

#bindGroup main {
  layout=auto
  entries=[
    { binding=0 buffer=$buffer.uniforms }
`;

  if (needsFeedback) {
    dsl += `    { binding=1 texture=$texture.feedback }
    { binding=2 sampler=$sampler.feedback }
`;
  }

  dsl += `  ]
}

#renderPipeline pipeline {
  vertex={ module=$wgsl.shader entryPoint="vs" }
  fragment={ module=$wgsl.shader entryPoint="fs" }
}

#renderPass render {
  pipeline=$renderPipeline.pipeline
  bindGroups=[$bindGroup.main]
  draw=3
}

#frame main {
  perform=[writeUniforms render]
}
`;

  return dsl;
}
```

---

## 10. Data Structures

### 10.1 Core TypeScript Interfaces

```typescript
// ═══════════════════════════════════════════════════════════════════════
// SHADER TYPES
// ═══════════════════════════════════════════════════════════════════════

type ShaderType = 'uv' | 'value' | 'color' | 'rgba' | 'texture';

interface MorphismType {
  input: ShaderType | ShaderType[] | 'any';
  output: ShaderType | 'same';
}

// ═══════════════════════════════════════════════════════════════════════
// PARAMETERS
// ═══════════════════════════════════════════════════════════════════════

type ParamType = 'float' | 'int' | 'vec2' | 'vec3' | 'color' | 'bool' | 'select' | 'angle';

interface CardParam {
  name: string;
  label: string;
  type: ParamType;
  default: ParamValue;
  range?: [number, number];
  step?: number;
  options?: { value: string; label: string }[];
  group?: string;
  advanced?: boolean;
  animatable?: boolean;
}

type ParamValue = number | boolean | string | number[];

type ParamValues = Record<string, ParamValue>;

// ═══════════════════════════════════════════════════════════════════════
// CARDS
// ═══════════════════════════════════════════════════════════════════════

type CardKind = 'primitive' | 'composite' | 'combinator' | 'functor' | 'saved';

interface CardBase {
  id: string;
  name: string;
  description: string;
  icon: string;
  tags: string[];
  signature: MorphismType;
  params: CardParam[];
}

interface PrimitiveCard extends CardBase {
  kind: 'primitive';
  lygiaImports: string[];
  wgslTemplate: string;  // e.g., 'cnoise({input} * {scale})'
}

interface CompositeCard extends CardBase {
  kind: 'composite';
  composition: CardInstance[];  // Linear composition
}

interface CombinatorCard extends CardBase {
  kind: 'combinator';
  combinator: 'pipe' | 'product' | 'sum' | 'fix' | 'lift' | 'lambda';
  slots: CardSlot[];
}

interface CardSlot {
  name: string;
  label: string;
  accepts: MorphismType;
  required: boolean;
  default?: CardInstance;
}

interface FunctorCard extends CardBase {
  kind: 'functor';
  uvTransform?: string;
  outputTransform?: string;
  setup?: string;
  requires?: {
    feedbackTexture?: boolean;
    additionalBindings?: BindingRequirement[];
  };
}

interface SavedCard extends CardBase {
  kind: 'saved';
  composition: CompositionGraph;
  exposedParams: ExposedParam[];
  thumbnail: string;
  author: string;
}

type Card = PrimitiveCard | CompositeCard | CombinatorCard | FunctorCard | SavedCard;

// ═══════════════════════════════════════════════════════════════════════
// INSTANCES
// ═══════════════════════════════════════════════════════════════════════

interface CardInstance {
  cardId: string;
  instanceId: string;
  params: ParamValues;
  enabled: boolean;

  // For combinators: nested cards
  slots?: Record<string, CardInstance>;
}

interface FunctorInstance {
  functorId: string;
  instanceId: string;
  params: ParamValues;
  enabled: boolean;
}

// ═══════════════════════════════════════════════════════════════════════
// COMPOSITION
// ═══════════════════════════════════════════════════════════════════════

interface ColumnState {
  cards: CardInstance[];
}

interface CompositionGraph {
  functors: FunctorInstance[];
  domain: ColumnState;
  structure: ColumnState;
  codomain: ColumnState;
  settings: CompositionSettings;
}

interface CompositionSettings {
  resolution: { width: number; height: number };
  background: number[];  // RGBA
}

interface ExposedParam {
  path: string;
  name: string;
  label: string;
  overrides?: Partial<CardParam>;
}

// ═══════════════════════════════════════════════════════════════════════
// COMPILATION
// ═══════════════════════════════════════════════════════════════════════

interface CompilationResult {
  wgsl: string;
  pngineDSL: string;
  uniforms: UniformField[];
  errors: CompilationError[];
  warnings: CompilationWarning[];
  size: number;  // Estimated bytes
}

interface UniformField {
  name: string;
  type: string;
  path: string;
  defaultValue: ParamValue;
}

interface CompilationError {
  location: string;
  message: string;
  severity: 'error' | 'warning';
}
```

### 10.2 State Management (Zustand)

```typescript
import { create } from 'zustand';
import { persist, subscribeWithSelector } from 'zustand/middleware';
import { immer } from 'zustand/middleware/immer';

interface ComposerState {
  // ─── Composition State ───────────────────────────────────────────────
  graph: CompositionGraph;

  // ─── UI State ────────────────────────────────────────────────────────
  selectedCard: string | null;
  selectedColumn: 'domain' | 'structure' | 'codomain' | null;
  expandedCards: Set<string>;
  showAdvancedParams: boolean;
  previewSize: { width: number; height: number };

  // ─── Compilation State ───────────────────────────────────────────────
  compiledWGSL: string | null;
  compiledDSL: string | null;
  compilationErrors: CompilationError[];
  estimatedSize: number;

  // ─── Library State ───────────────────────────────────────────────────
  userCards: SavedCard[];
  cardFilter: string;
  cardCategory: string | null;

  // ─── Actions ─────────────────────────────────────────────────────────

  // Card management
  addCard: (cardId: string, column: 'domain' | 'structure' | 'codomain') => void;
  removeCard: (instanceId: string) => void;
  moveCard: (instanceId: string, newIndex: number) => void;
  updateCardParam: (instanceId: string, paramName: string, value: ParamValue) => void;
  toggleCard: (instanceId: string) => void;
  selectCard: (instanceId: string | null) => void;

  // Combinator slots
  setSlotCard: (instanceId: string, slotName: string, card: CardInstance) => void;
  clearSlot: (instanceId: string, slotName: string) => void;

  // Functors
  addFunctor: (functorId: string) => void;
  removeFunctor: (instanceId: string) => void;
  updateFunctorParam: (instanceId: string, paramName: string, value: ParamValue) => void;
  reorderFunctors: (fromIndex: number, toIndex: number) => void;

  // Composition
  compile: () => CompilationResult;
  reset: () => void;
  loadFromURL: (encoded: string) => void;
  saveToURL: () => string;

  // Library
  saveAsCard: (name: string, exposedParams: ExposedParam[]) => SavedCard;
  deleteUserCard: (cardId: string) => void;
  exportCard: (cardId: string) => string;
  importCard: (json: string) => void;
}

export const useComposer = create<ComposerState>()(
  subscribeWithSelector(
    persist(
      immer((set, get) => ({
        // Initial state
        graph: createEmptyGraph(),
        selectedCard: null,
        selectedColumn: null,
        expandedCards: new Set(),
        showAdvancedParams: false,
        previewSize: { width: 512, height: 512 },
        compiledWGSL: null,
        compiledDSL: null,
        compilationErrors: [],
        estimatedSize: 0,
        userCards: [],
        cardFilter: '',
        cardCategory: null,

        // Actions
        addCard: (cardId, column) => set(state => {
          const card = getCardDefinition(cardId);
          const instance: CardInstance = {
            cardId,
            instanceId: `${cardId}-${Date.now()}`,
            params: getDefaultParams(card),
            enabled: true,
          };
          state.graph[column].cards.push(instance);
        }),

        removeCard: (instanceId) => set(state => {
          for (const column of ['domain', 'structure', 'codomain'] as const) {
            const idx = state.graph[column].cards.findIndex(c => c.instanceId === instanceId);
            if (idx !== -1) {
              state.graph[column].cards.splice(idx, 1);
              break;
            }
          }
        }),

        updateCardParam: (instanceId, paramName, value) => set(state => {
          const card = findCard(state.graph, instanceId);
          if (card) {
            card.params[paramName] = value;
          }
        }),

        compile: () => {
          const state = get();
          try {
            const result = compileGraph(state.graph);
            set({
              compiledWGSL: result.wgsl,
              compiledDSL: result.pngineDSL,
              compilationErrors: result.errors,
              estimatedSize: result.size,
            });
            return result;
          } catch (e) {
            const error = { location: 'root', message: String(e), severity: 'error' as const };
            set({ compilationErrors: [error] });
            return { wgsl: '', pngineDSL: '', uniforms: [], errors: [error], warnings: [], size: 0 };
          }
        },

        saveAsCard: (name, exposedParams) => {
          const state = get();
          const card: SavedCard = {
            kind: 'saved',
            id: `user-${Date.now()}`,
            name,
            description: '',
            icon: '📦',
            tags: ['user'],
            signature: inferGraphSignature(state.graph),
            params: exposedParams.map(ep => ({
              ...getParamAtPath(state.graph, ep.path),
              ...ep.overrides,
              name: ep.name,
              label: ep.label,
            })),
            composition: structuredClone(state.graph),
            exposedParams,
            thumbnail: '', // TODO: render thumbnail
            author: 'User',
          };

          set(state => {
            state.userCards.push(card);
          });

          return card;
        },

        // ... more actions
      })),
      {
        name: 'pngine-composer',
        partialize: (state) => ({
          graph: state.graph,
          userCards: state.userCards,
          showAdvancedParams: state.showAdvancedParams,
        }),
      }
    )
  )
);

// Auto-recompile on graph changes
useComposer.subscribe(
  (state) => state.graph,
  () => useComposer.getState().compile(),
  { equalityFn: shallow }
);
```

---

## 11. User Interface

### 11.1 Component Hierarchy

```
App
├── Header
│   ├── Logo
│   ├── FileMenu (New, Load, Save, Export)
│   └── HelpButton
│
├── Workspace
│   ├── FunctorBar
│   │   └── FunctorChip[] (removable, draggable)
│   │
│   ├── ColumnsContainer
│   │   ├── Column (domain)
│   │   │   ├── ColumnHeader
│   │   │   ├── CardStack
│   │   │   │   └── CardComponent[]
│   │   │   └── AddCardButton
│   │   │
│   │   ├── PreviewColumn
│   │   │   ├── ShaderCanvas (WebGPU)
│   │   │   ├── PreviewControls (size, time)
│   │   │   └── SizeIndicator
│   │   │
│   │   └── Column (structure, codomain)
│   │
│   └── CombinatorBar
│       └── CombinatorButton[]
│
├── CardDeck
│   ├── FilterBar
│   │   ├── CategoryFilter
│   │   └── SearchInput
│   └── CardGrid
│       └── CardThumbnail[]
│
├── ActionBar
│   ├── ViewCodeButton
│   ├── CopyDSLButton
│   ├── DownloadPNGButton
│   ├── ShareButton
│   └── SaveAsCardButton
│
└── Modals
    ├── CodeViewModal
    ├── SaveCardModal
    └── HelpModal
```

### 11.2 Card Component

```tsx
interface CardComponentProps {
  instance: CardInstance;
  onParamChange: (name: string, value: ParamValue) => void;
  onRemove: () => void;
  onToggle: () => void;
  isSelected: boolean;
  isExpanded: boolean;
  onSelect: () => void;
  onExpand: () => void;
}

function CardComponent({
  instance,
  onParamChange,
  onRemove,
  onToggle,
  isSelected,
  isExpanded,
  onSelect,
  onExpand,
}: CardComponentProps) {
  const card = getCardDefinition(instance.cardId);

  return (
    <div
      className={cn(
        'card',
        isSelected && 'card--selected',
        !instance.enabled && 'card--disabled',
      )}
      onClick={onSelect}
    >
      {/* Header */}
      <div className="card__header">
        <span className="card__icon">{card.icon}</span>
        <span className="card__name">{card.name}</span>
        <button className="card__remove" onClick={onRemove}>×</button>
      </div>

      {/* Parameters (when expanded) */}
      {isExpanded && (
        <div className="card__params">
          {card.params.map(param => (
            <ParamControl
              key={param.name}
              param={param}
              value={instance.params[param.name]}
              onChange={(v) => onParamChange(param.name, v)}
            />
          ))}

          {/* Combinator slots */}
          {card.kind === 'combinator' && (
            <div className="card__slots">
              {card.slots.map(slot => (
                <SlotDropzone
                  key={slot.name}
                  slot={slot}
                  filled={instance.slots?.[slot.name]}
                />
              ))}
            </div>
          )}
        </div>
      )}

      {/* Actions */}
      <div className="card__actions">
        <button onClick={() => /* move up */}>↑</button>
        <button onClick={() => /* move down */}>↓</button>
        <button onClick={onToggle}>{instance.enabled ? '👁' : '👁‍🗨'}</button>
        <button onClick={onExpand}>{isExpanded ? '▲' : '▼'}</button>
      </div>
    </div>
  );
}
```

### 11.3 Drag and Drop

Using `@dnd-kit/core` for drag and drop:

```tsx
import {
  DndContext,
  DragOverlay,
  closestCenter,
  KeyboardSensor,
  PointerSensor,
  useSensor,
  useSensors,
} from '@dnd-kit/core';
import {
  SortableContext,
  sortableKeyboardCoordinates,
  verticalListSortingStrategy,
} from '@dnd-kit/sortable';

function Workspace() {
  const [activeId, setActiveId] = useState<string | null>(null);
  const { graph, addCard, moveCard } = useComposer();

  const sensors = useSensors(
    useSensor(PointerSensor),
    useSensor(KeyboardSensor, {
      coordinateGetter: sortableKeyboardCoordinates,
    })
  );

  function handleDragStart(event: DragStartEvent) {
    setActiveId(event.active.id as string);
  }

  function handleDragEnd(event: DragEndEvent) {
    const { active, over } = event;

    if (!over) return;

    // Dragging from deck to column
    if (active.data.current?.type === 'deck-card') {
      const cardId = active.data.current.cardId;
      const column = over.data.current?.column;
      if (column) {
        addCard(cardId, column);
      }
    }

    // Reordering within column
    if (active.data.current?.type === 'column-card') {
      // ... handle reorder
    }

    setActiveId(null);
  }

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={closestCenter}
      onDragStart={handleDragStart}
      onDragEnd={handleDragEnd}
    >
      <div className="workspace">
        <FunctorBar />
        <ColumnsContainer />
        <CombinatorBar />
      </div>

      <DragOverlay>
        {activeId && <CardDragPreview id={activeId} />}
      </DragOverlay>
    </DndContext>
  );
}
```

### 11.4 WebGPU Preview

```tsx
function ShaderPreview() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const rendererRef = useRef<ShaderRenderer | null>(null);
  const { compiledWGSL, graph, previewSize } = useComposer();

  // Initialize renderer
  useEffect(() => {
    if (!canvasRef.current) return;

    (async () => {
      const renderer = await ShaderRenderer.create(canvasRef.current!);
      rendererRef.current = renderer;
    })();

    return () => {
      rendererRef.current?.destroy();
    };
  }, []);

  // Update shader when compiled
  useEffect(() => {
    if (!rendererRef.current || !compiledWGSL) return;

    rendererRef.current.updateShader(compiledWGSL)
      .catch(err => console.error('Shader compilation failed:', err));
  }, [compiledWGSL]);

  // Animation loop
  useEffect(() => {
    if (!rendererRef.current) return;

    let animationId: number;
    const startTime = performance.now();

    function render() {
      const time = (performance.now() - startTime) / 1000;
      rendererRef.current?.render(time);
      animationId = requestAnimationFrame(render);
    }

    render();

    return () => cancelAnimationFrame(animationId);
  }, []);

  return (
    <div className="preview">
      <canvas
        ref={canvasRef}
        width={previewSize.width}
        height={previewSize.height}
      />
      <div className="preview__size">
        {estimatedSize} bytes
      </div>
    </div>
  );
}
```

---

## 12. Implementation Phases

### Phase 1: Foundation (2 weeks)

**Goal**: Basic card composition with live preview

**Tasks**:
- [ ] Project setup (Next.js 14 + TypeScript + Tailwind)
- [ ] Zustand store with basic state
- [ ] Three-column layout component
- [ ] Card component (primitive cards only)
- [ ] Drag-drop from deck to columns (@dnd-kit)
- [ ] 15 primitive cards (5 space, 5 gen, 5 color)
- [ ] Basic WGSL generation (no combinators)
- [ ] WebGPU preview canvas
- [ ] Live compilation on state change

**Deliverables**:
- Can drag Noise to structure, Rainbow to codomain
- See live result in preview
- Basic parameter sliders work

### Phase 2: Card System (2 weeks)

**Goal**: Full card interaction and type system

**Tasks**:
- [ ] Type checking system
- [ ] Auto-coercion between types
- [ ] Card reordering within columns
- [ ] Card enable/disable toggle
- [ ] Parameter groups and advanced mode
- [ ] 30 total primitive cards
- [ ] Card search and filtering
- [ ] Column type indicators
- [ ] Error highlighting

**Deliverables**:
- Type errors shown in UI
- Can build complex multi-card compositions
- All lygia primitives wrapped

### Phase 3: Combinators (2 weeks)

**Goal**: Higher-order composition

**Tasks**:
- [ ] Pipe combinator (>>>)
- [ ] Product combinator (⊗) with merge modes
- [ ] Sum combinator (⊕) with selector
- [ ] Combinator UI (nested cards, slots)
- [ ] Combinator compilation
- [ ] Drag cards into combinator slots
- [ ] Visual nesting representation

**Deliverables**:
- Can create `(noise ⊗ circle) >>> rainbow`
- Combinators compile to valid WGSL
- Visual hierarchy clear

### Phase 4: Functors (2 weeks)

**Goal**: Composition wrappers

**Tasks**:
- [ ] Tile functor
- [ ] Mirror functor
- [ ] Kaleidoscope functor
- [ ] Feedback functor (requires multi-pass)
- [ ] Temporal functor
- [ ] Functor bar UI
- [ ] Functor stacking
- [ ] Functor compilation

**Deliverables**:
- Can wrap entire composition in Tile
- Feedback loop creates trails
- Functors can be stacked

### Phase 5: Recursion & Save (2 weeks)

**Goal**: Fix combinator and saved cards

**Tasks**:
- [ ] Fix combinator (μ)
- [ ] Loop unrolling compilation
- [ ] Save composition as card
- [ ] Expose parameter selection UI
- [ ] User card library (localStorage)
- [ ] Export/import cards (JSON)
- [ ] Thumbnail generation

**Deliverables**:
- Can create fractal patterns with Fix
- Saved cards appear in deck
- Can share cards as JSON

### Phase 6: Export & Polish (2 weeks)

**Goal**: Production-ready application

**Tasks**:
- [ ] PNGine DSL generation
- [ ] Integration with PNGine WASM compiler
- [ ] Download .png with embedded bytecode
- [ ] URL-based state sharing
- [ ] Undo/redo (with zustand-middleware)
- [ ] Keyboard shortcuts
- [ ] Responsive design (mobile-friendly)
- [ ] Loading states and error handling
- [ ] 50+ total cards
- [ ] Preset compositions

**Deliverables**:
- Can download working PNG
- Share via URL
- Polished UX

### Phase 7: Community (Future)

**Goal**: Community features

**Tasks**:
- [ ] User accounts
- [ ] Publish cards to gallery
- [ ] Browse community cards
- [ ] Fork compositions
- [ ] Comments and likes
- [ ] Featured compositions

---

## 13. Examples

### 13.1 Hello World: Tiled Rainbow Circle

The simplest possible example using all three columns. One card per column,
demonstrating the complete categorical pipeline.

**Visual Layout**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   DOMAIN              STRUCTURE              CODOMAIN                       │
│   (UV → UV)           (UV → Value)           (Value → Color)                │
│                                                                             │
│   ┌───────────┐       ┌───────────┐          ┌───────────┐                 │
│   │ 🔲 Tile   │       │ ⭕ Circle │          │ 🌈 Rainbow│                 │
│   │           │       │           │          │           │                 │
│   │ x: 3      │  ───▶ │ radius:   │   ───▶   │ offset: 0 │                 │
│   │ y: 3      │       │ 0.4       │          │           │                 │
│   └───────────┘       └───────────┘          └───────────┘                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Data Flow**:

```
UV (0-1)
    │
    ▼
┌────────┐      ┌────────────┐      ┌────────────┐      ┌───────┐
│  Tile  │ ───▶ │   Circle   │ ───▶ │  Rainbow   │ ───▶ │ Pixel │
│  3×3   │      │  r = 0.4   │      │  spectral  │      │ Color │
└────────┘      └────────────┘      └────────────┘      └───────┘

UV → UV         UV → Value          Value → Color
```

**Composition Graph**:

```typescript
const helloWorld: CompositionGraph = {
  functors: [],

  domain: {
    cards: [{
      cardId: 'tile',
      instanceId: 'tile-1',
      params: { countX: 3, countY: 3 },
      enabled: true,
    }],
  },

  structure: {
    cards: [{
      cardId: 'circle-sdf',
      instanceId: 'circle-1',
      params: { radius: 0.4, centerX: 0.5, centerY: 0.5, softness: 0.02 },
      enabled: true,
    }],
  },

  codomain: {
    cards: [{
      cardId: 'rainbow',
      instanceId: 'rainbow-1',
      params: { offset: 0.0, cycles: 1.0 },
      enabled: true,
    }],
  },

  settings: { resolution: { width: 512, height: 512 } },
};
```

**Generated WGSL**:

```wgsl
// ═══════════════════════════════════════════════════════════════
// Hello World: Tiled Rainbow Circle
// Generated by PNGine Composer
// ═══════════════════════════════════════════════════════════════

struct Uniforms {
  time: f32,
  resolution: vec2f,
}
@group(0) @binding(0) var<uniform> u: Uniforms;

// ─── Lygia: Circle SDF ─────────────────────────────────────────
fn circleSDF(p: vec2f, r: f32) -> f32 {
  return length(p) - r;
}

// ─── Lygia: Spectral Palette ───────────────────────────────────
fn spectral(t: f32) -> vec3f {
  return clamp(abs(fract(t + vec3f(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0) - 1.0,
               vec3f(0.0), vec3f(1.0));
}

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  var uv = pos.xy / u.resolution;
  uv.y = 1.0 - uv.y;

  // ─── DOMAIN: Tile 3×3 ────────────────────────────────────────
  let tiledUV = fract(uv * vec2f(3.0, 3.0));

  // ─── STRUCTURE: Circle SDF ───────────────────────────────────
  let dist = circleSDF(tiledUV - vec2f(0.5, 0.5), 0.4);
  let value = 1.0 - smoothstep(0.0, 0.02, dist);

  // ─── CODOMAIN: Rainbow ───────────────────────────────────────
  let color = spectral(value);

  return vec4f(color, 1.0);
}
```

**Visual Result**: A 3×3 grid of circles, each filled with a rainbow gradient
(violet at center, red at edges).

**Why This Works as Hello World**:

| Aspect | Simplicity |
|--------|------------|
| Cards | One per column (minimum) |
| Combinators | None |
| Functors | None |
| Type flow | UV → UV → Value → Color (complete pipeline) |
| Visual feedback | Immediately see all three columns working |

---

### 13.2 First Combinator: Masked Noise

Introduces the **Product (⊗)** combinator to blend two generators. This creates
noise that only appears inside a circle - a fundamental composition pattern.

**Visual Layout**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   DOMAIN              STRUCTURE                    CODOMAIN                 │
│   (UV → UV)           (UV → Value)                 (Value → Color)          │
│                                                                             │
│   ┌───────────┐       ┌─────────────────────┐      ┌───────────┐           │
│   │ 🔲 Tile   │       │ ⊗ PRODUCT           │      │ 🔥 Heatmap│           │
│   │           │       │ merge: multiply      │      │           │           │
│   │ x: 2      │  ───▶ │ ┌───────┬─────────┐ │ ───▶ │ offset: 0 │           │
│   │ y: 2      │       │ │   A   │    B    │ │      │           │           │
│   └───────────┘       │ │ ┌───┐ │ ┌─────┐ │ │      └───────────┘           │
│                       │ │ │🌊 │ │ │ ⭕  │ │ │                               │
│                       │ │ │Noi│ │ │Circl│ │ │                               │
│                       │ │ │se │ │ │ e   │ │ │                               │
│                       │ │ │s:6│ │ │r:0.4│ │ │                               │
│                       │ │ └───┘ │ └─────┘ │ │                               │
│                       │ └───────┴─────────┘ │                               │
│                       └─────────────────────┘                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Data Flow**:

```
                                    ┌─────────┐
                              ┌────▶│  Noise  │────┐
                              │     │  (s:6)  │    │
UV ───▶ Tile ───▶ UV' ────────┤     └─────────┘    ├───▶ × ───▶ Heatmap ───▶ Color
         2×2                  │     ┌─────────┐    │      multiply
                              └────▶│ Circle  │────┘
                                    │ (r:0.4) │
                                    └─────────┘

Type: UV → UV → (Value × Value) → Value → Color
```

**Composition Graph**:

```typescript
const maskedNoise: CompositionGraph = {
  functors: [],

  domain: {
    cards: [{
      cardId: 'tile',
      instanceId: 'tile-1',
      params: { countX: 2, countY: 2 },
      enabled: true,
    }],
  },

  structure: {
    cards: [{
      cardId: 'product',  // ⊗ Combinator
      instanceId: 'product-1',
      params: { merge: 'multiply' },
      slots: {
        left: {
          cardId: 'noise',
          instanceId: 'noise-inner',
          params: { scale: 6.0, speed: 0.5 },
          enabled: true,
        },
        right: {
          cardId: 'circle-sdf',
          instanceId: 'circle-inner',
          params: { radius: 0.4, centerX: 0.5, centerY: 0.5, softness: 0.02 },
          enabled: true,
        },
      },
      enabled: true,
    }],
  },

  codomain: {
    cards: [{
      cardId: 'heatmap',
      instanceId: 'heatmap-1',
      params: { offset: 0.0 },
      enabled: true,
    }],
  },

  settings: { resolution: { width: 512, height: 512 } },
};
```

**Generated WGSL**:

```wgsl
// ═══════════════════════════════════════════════════════════════
// First Combinator: Masked Noise
// Uses Product (⊗) to multiply noise with circle mask
// ═══════════════════════════════════════════════════════════════

struct Uniforms {
  time: f32,
  resolution: vec2f,
}
@group(0) @binding(0) var<uniform> u: Uniforms;

// ─── Lygia: Perlin Noise ───────────────────────────────────────
fn mod289(x: vec2f) -> vec2f { return x - floor(x * (1.0 / 289.0)) * 289.0; }
fn mod289_3(x: vec3f) -> vec3f { return x - floor(x * (1.0 / 289.0)) * 289.0; }
fn permute(x: vec3f) -> vec3f { return mod289_3(((x * 34.0) + 1.0) * x); }

fn cnoise(P: vec2f) -> f32 {
  var Pi = floor(P.xyxy) + vec4f(0.0, 0.0, 1.0, 1.0);
  let Pf = fract(P.xyxy) - vec4f(0.0, 0.0, 1.0, 1.0);
  Pi = mod289(Pi.xyxy);
  let ix = Pi.xzxz;
  let iy = Pi.yyww;
  let fx = Pf.xzxz;
  let fy = Pf.yyww;
  let i = permute(permute(ix) + iy);
  var gx = fract(i * (1.0 / 41.0)) * 2.0 - 1.0;
  let gy = abs(gx) - 0.5;
  let tx = floor(gx + 0.5);
  gx = gx - tx;
  var g00 = vec2f(gx.x, gy.x);
  var g10 = vec2f(gx.y, gy.y);
  var g01 = vec2f(gx.z, gy.z);
  var g11 = vec2f(gx.w, gy.w);
  let norm = 1.79284291400159 - 0.85373472095314 *
    vec4f(dot(g00, g00), dot(g01, g01), dot(g10, g10), dot(g11, g11));
  g00 *= norm.x; g01 *= norm.y; g10 *= norm.z; g11 *= norm.w;
  let n00 = dot(g00, vec2f(fx.x, fy.x));
  let n10 = dot(g10, vec2f(fx.y, fy.y));
  let n01 = dot(g01, vec2f(fx.z, fy.z));
  let n11 = dot(g11, vec2f(fx.w, fy.w));
  let fade_xy = Pf.xy * Pf.xy * Pf.xy * (Pf.xy * (Pf.xy * 6.0 - 15.0) + 10.0);
  let n_x = mix(vec2f(n00, n01), vec2f(n10, n11), fade_xy.x);
  let n_xy = mix(n_x.x, n_x.y, fade_xy.y);
  return 2.3 * n_xy;
}

// ─── Lygia: Circle SDF ─────────────────────────────────────────
fn circleSDF(p: vec2f, r: f32) -> f32 {
  return length(p) - r;
}

// ─── Lygia: Heatmap Palette ────────────────────────────────────
fn heatmap(t: f32) -> vec3f {
  return clamp(vec3f(
    min(t * 3.0, 1.0),
    clamp(t * 3.0 - 1.0, 0.0, 1.0),
    clamp(t * 3.0 - 2.0, 0.0, 1.0)
  ), vec3f(0.0), vec3f(1.0));
}

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  var uv = pos.xy / u.resolution;
  uv.y = 1.0 - uv.y;
  let time = u.time;

  // ─── DOMAIN: Tile 2×2 ────────────────────────────────────────
  let tiledUV = fract(uv * vec2f(2.0, 2.0));

  // ─── STRUCTURE: Product (Noise ⊗ Circle) ─────────────────────
  // Slot A: Noise
  let noiseVal = cnoise(tiledUV * 6.0 + time * 0.5) * 0.5 + 0.5;

  // Slot B: Circle
  let dist = circleSDF(tiledUV - vec2f(0.5, 0.5), 0.4);
  let circleVal = 1.0 - smoothstep(0.0, 0.02, dist);

  // Merge: multiply
  let value = noiseVal * circleVal;

  // ─── CODOMAIN: Heatmap ───────────────────────────────────────
  let color = heatmap(value);

  return vec4f(color, 1.0);
}
```

**Visual Result**: A 2×2 grid where each cell contains animated noise that only
appears inside a circle, colored with a cold-to-hot gradient.

**Key Concepts Demonstrated**:

| Concept | How It's Shown |
|---------|----------------|
| **Product (⊗)** | Noise and Circle evaluated in parallel, then multiplied |
| **Slots** | The combinator has `left` and `right` slots for inner cards |
| **Type preservation** | Both slots output Value, merge produces Value |
| **Masking pattern** | Circle acts as a mask (0 outside, 1 inside) |
| **Animation** | Noise uses `time` parameter for movement |

**Categorical Interpretation**:

```
⊗ : (UV → Value) × (UV → Value) → (UV → Value)

Given:
  noise  : UV → Value
  circle : UV → Value

Product creates:
  (noise ⊗ circle) : UV → Value
  (noise ⊗ circle)(uv) = noise(uv) * circle(uv)
```

---

### 13.3 Functor Wrapper: Kaleidoscope Spiral

Demonstrates **functor wrappers** that transform the entire composition. The
Kaleidoscope functor wraps around all three columns, applying radial symmetry
to whatever is inside.

**Visual Layout**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   ╔═══════════════════════════════════════════════════════════════════════╗ │
│   ║  ❄️ KALEIDOSCOPE                                                      ║ │
│   ║  segments: 8   rotation: time * 30                                    ║ │
│   ║                                                                        ║ │
│   ║    DOMAIN              STRUCTURE              CODOMAIN                 ║ │
│   ║    (UV → UV)           (UV → Value)           (Value → Color)          ║ │
│   ║                                                                        ║ │
│   ║    ┌───────────┐       ┌───────────┐          ┌───────────┐           ║ │
│   ║    │ 🌀 Spiral │       │ 🌊 FBM    │          │ 🔥 Heatmap│           ║ │
│   ║    │           │       │           │          │           │           ║ │
│   ║    │ twist:    │  ───▶ │ octaves:  │   ───▶   │ offset: 0 │           ║ │
│   ║    │ 2.0       │       │ 4         │          │           │           ║ │
│   ║    └───────────┘       └───────────┘          └───────────┘           ║ │
│   ║                                                                        ║ │
│   ╚═══════════════════════════════════════════════════════════════════════╝ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Data Flow**:

```
                    ┌─────────────────────────────────────────────┐
                    │            ❄️ Kaleidoscope(8)               │
UV ────────────────▶│                                             │
                    │     UV' = kaleidoscope(UV, segments=8)      │
                    │              │                               │
                    │              ▼                               │
                    │   ┌────────┐      ┌────────┐      ┌───────┐ │
                    │   │ Spiral │ ───▶ │  FBM   │ ───▶ │Heatmap│ │
                    │   │twist=2 │      │ oct=4  │      │       │ │
                    │   └────────┘      └────────┘      └───────┘ │
                    │              │                               │
                    │              ▼                               │────▶ Color
                    │         Inner result                        │
                    └─────────────────────────────────────────────┘

Functor law: Kaleidoscope(f ∘ g) = Kaleidoscope(f) ∘ Kaleidoscope(g)
Both see the same kaleidoscoped UV coordinates.
```

**Composition Graph**:

```typescript
const kaleidoscopeSpiral: CompositionGraph = {
  // Functor wraps the entire composition
  functors: [{
    functorId: 'kaleidoscope',
    instanceId: 'kaleido-1',
    params: {
      segments: 8,
      rotation: 'time * 30',  // Animated rotation
    },
    enabled: true,
  }],

  domain: {
    cards: [{
      cardId: 'spiral',
      instanceId: 'spiral-1',
      params: { twist: 2.0, centerX: 0.5, centerY: 0.5 },
      enabled: true,
    }],
  },

  structure: {
    cards: [{
      cardId: 'fbm',
      instanceId: 'fbm-1',
      params: { octaves: 4, lacunarity: 2.0, gain: 0.5, scale: 3.0 },
      enabled: true,
    }],
  },

  codomain: {
    cards: [{
      cardId: 'heatmap',
      instanceId: 'heatmap-1',
      params: { offset: 0.0 },
      enabled: true,
    }],
  },

  settings: { resolution: { width: 512, height: 512 } },
};
```

**Generated WGSL**:

```wgsl
// ═══════════════════════════════════════════════════════════════
// Functor Wrapper: Kaleidoscope Spiral
// Demonstrates functor that wraps entire composition
// ═══════════════════════════════════════════════════════════════

struct Uniforms {
  time: f32,
  resolution: vec2f,
}
@group(0) @binding(0) var<uniform> u: Uniforms;

const PI: f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;

// ─── Lygia: Simplex Noise ─────────────────────────────────────
fn mod289(x: vec3f) -> vec3f { return x - floor(x * (1.0/289.0)) * 289.0; }
fn mod289_4(x: vec4f) -> vec4f { return x - floor(x * (1.0/289.0)) * 289.0; }
fn permute(x: vec4f) -> vec4f { return mod289_4(((x * 34.0) + 1.0) * x); }
fn taylorInvSqrt(r: vec4f) -> vec4f { return 1.79284291400159 - 0.85373472095314 * r; }

fn snoise(v: vec2f) -> f32 {
  let C = vec4f(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
  var i = floor(v + dot(v, C.yy));
  let x0 = v - i + dot(i, C.xx);
  var i1 = select(vec2f(0.0, 1.0), vec2f(1.0, 0.0), x0.x > x0.y);
  var x12 = x0.xyxy + C.xxzz;
  x12 = vec4f(x12.xy - i1, x12.zw);
  i = mod289(i.xyxy).xy;
  let p = permute(permute(i.y + vec4f(0.0, i1.y, 1.0, 0.0)) + i.x + vec4f(0.0, i1.x, 1.0, 0.0));
  var m = max(0.5 - vec4f(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw), 0.0), vec4f(0.0));
  m = m * m;
  m = m * m;
  let x = 2.0 * fract(p * C.wwww) - 1.0;
  let h = abs(x) - 0.5;
  let ox = floor(x + 0.5);
  let a0 = x - ox;
  m *= taylorInvSqrt(a0 * a0 + h * h);
  let g = vec3f(a0.x * x0.x + h.x * x0.y, a0.yz * x12.xz + h.yz * x12.yw);
  return 130.0 * dot(m.xyz, g);
}

// ─── Lygia: FBM ───────────────────────────────────────────────
fn fbm(p: vec2f, octaves: i32) -> f32 {
  var value = 0.0;
  var amplitude = 0.5;
  var frequency = 1.0;
  var pos = p;
  for (var i = 0; i < octaves; i++) {
    value += amplitude * snoise(pos * frequency);
    frequency *= 2.0;
    amplitude *= 0.5;
  }
  return value * 0.5 + 0.5;  // Normalize to [0, 1]
}

// ─── Lygia: Heatmap Palette ───────────────────────────────────
fn heatmap(t: f32) -> vec3f {
  return clamp(vec3f(
    min(t * 3.0, 1.0),
    clamp(t * 3.0 - 1.0, 0.0, 1.0),
    clamp(t * 3.0 - 2.0, 0.0, 1.0)
  ), vec3f(0.0), vec3f(1.0));
}

// ─── Kaleidoscope UV Transform ────────────────────────────────
fn kaleidoscope(uv: vec2f, segments: f32, rotation: f32) -> vec2f {
  let centered = uv - 0.5;
  var angle = atan2(centered.y, centered.x) + rotation;
  let radius = length(centered);

  let segmentAngle = TAU / segments;
  // Mirror within segment for seamless symmetry
  angle = (angle % segmentAngle + segmentAngle) % segmentAngle;
  if (angle > segmentAngle * 0.5) {
    angle = segmentAngle - angle;
  }

  return vec2f(cos(angle), sin(angle)) * radius + 0.5;
}

// ─── Spiral UV Transform ──────────────────────────────────────
fn spiral(uv: vec2f, twist: f32) -> vec2f {
  let centered = uv - 0.5;
  let radius = length(centered);
  let angle = atan2(centered.y, centered.x) + radius * twist * TAU;
  return vec2f(cos(angle), sin(angle)) * radius + 0.5;
}

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  var uv = pos.xy / u.resolution;
  uv.y = 1.0 - uv.y;
  let time = u.time;

  // ═══ FUNCTOR: Kaleidoscope (wraps entire composition) ═══════
  let kaleidoUV = kaleidoscope(uv, 8.0, time * 0.5);

  // ─── DOMAIN: Spiral ─────────────────────────────────────────
  let spiralUV = spiral(kaleidoUV, 2.0);

  // ─── STRUCTURE: FBM Noise ───────────────────────────────────
  let value = fbm(spiralUV * 3.0 + time * 0.2, 4);

  // ─── CODOMAIN: Heatmap ──────────────────────────────────────
  let color = heatmap(value);

  return vec4f(color, 1.0);
}
```

**Visual Result**: An 8-fold symmetric kaleidoscope with spiraling FBM noise
colored in a cold-to-hot gradient. The pattern rotates slowly, creating a
mesmerizing mandala effect.

**Key Concepts Demonstrated**:

| Concept | How It's Shown |
|---------|----------------|
| **Functor wrapper** | Kaleidoscope wraps all three columns |
| **UV transformation** | Kaleidoscope modifies UV before inner cards see it |
| **Animated functor** | `rotation: time * 30` animates the functor params |
| **Functor law** | All inner cards see the same transformed UV |
| **Nesting** | Functor contains Domain → Structure → Codomain |

**Categorical Interpretation**:

```
Kaleidoscope : Shader → Shader   (endofunctor on Shader category)

Given inner composition:
  inner = heatmap ∘ fbm ∘ spiral : UV → Color

Kaleidoscope(inner) = heatmap ∘ fbm ∘ spiral ∘ kaleidoscope : UV → Color

Functor laws:
  Kaleidoscope(id) = id on kaleidoscoped domain  ✓
  Kaleidoscope(f ∘ g) = Kaleidoscope(f) ∘ Kaleidoscope(g)  ✓

The functor transforms the domain (UV) while preserving composition structure.
```

**Comparison: With vs Without Functor**:

| Without Kaleidoscope | With Kaleidoscope |
|----------------------|-------------------|
| Spiral pattern fills canvas | 8-fold symmetric mandala |
| One instance of pattern | Pattern reflected 8 times |
| Normal coordinates | Polar-symmetric coordinates |

---

### 13.4 Stacked Functors: Feedback over Tile

Demonstrates **functor stacking** where multiple functors wrap the composition.
Order matters: `Feedback(Tile(inner))` creates tiled trails, while
`Tile(Feedback(inner))` would tile the entire feedback buffer (different effect).

**Visual Layout**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   ╔═══════════════════════════════════════════════════════════════════════╗ │
│   ║  🔄 FEEDBACK                                                          ║ │
│   ║  persistence: 0.92   fadeColor: [0.02, 0.0, 0.05]                     ║ │
│   ║                                                                        ║ │
│   ║  ╔═══════════════════════════════════════════════════════════════════╗║ │
│   ║  ║  🔲 TILE                                                          ║║ │
│   ║  ║  countX: 3   countY: 3                                            ║║ │
│   ║  ║                                                                    ║║ │
│   ║  ║    DOMAIN              STRUCTURE              CODOMAIN             ║║ │
│   ║  ║                                                                    ║║ │
│   ║  ║    ┌───────────┐       ┌───────────┐          ┌───────────┐       ║║ │
│   ║  ║    │ 🌀 Rotate │       │ ⭕ Circle │          │ 🌈 Rainbow│       ║║ │
│   ║  ║    │           │       │           │          │           │       ║║ │
│   ║  ║    │ speed:    │  ───▶ │ radius:   │   ───▶   │ offset:   │       ║║ │
│   ║  ║    │ 0.5       │       │ 0.3       │          │ time*0.1  │       ║║ │
│   ║  ║    └───────────┘       └───────────┘          └───────────┘       ║║ │
│   ║  ║                                                                    ║║ │
│   ║  ╚═══════════════════════════════════════════════════════════════════╝║ │
│   ║                                                                        ║ │
│   ╚═══════════════════════════════════════════════════════════════════════╝ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Data Flow**:

```
                 ┌────────────────────────────────────────────────────────────────┐
                 │  🔄 Feedback                                                   │
                 │                                                                │
                 │   prevColor = sample(feedbackTexture, uv)                      │
                 │                    │                                           │
                 │   ┌────────────────┼──────────────────────────────────────┐   │
                 │   │  🔲 Tile 3×3   │                                      │   │
                 │   │                ▼                                      │   │
UV ─────────────▶│   │     tiledUV = fract(uv * 3)                          │   │
                 │   │                │                                      │   │
                 │   │   ┌────────┐   │   ┌────────┐      ┌─────────┐       │   │
                 │   │   │ Rotate │◀──┘   │ Circle │      │ Rainbow │       │   │
                 │   │   │ 0.5/s  │──────▶│ r=0.3  │─────▶│  hue    │       │   │
                 │   │   └────────┘       └────────┘      └─────────┘       │   │
                 │   │                          │                            │   │
                 │   └──────────────────────────┼────────────────────────────┘   │
                 │                              ▼                                 │
                 │                         innerColor                             │
                 │                              │                                 │
                 │                              ▼                                 │
                 │              mix(innerColor, prevColor, 0.92) ────────────────▶│──▶ Color
                 │                                                                │
                 └────────────────────────────────────────────────────────────────┘

Functor composition: Feedback ∘ Tile (outer applied last)
```

**Composition Graph**:

```typescript
const feedbackTiledCircles: CompositionGraph = {
  // Stacked functors: outer listed first, applied outside-in
  functors: [
    {
      functorId: 'feedback',
      instanceId: 'feedback-1',
      params: {
        persistence: 0.92,
        fadeColor: [0.02, 0.0, 0.05],  // Subtle purple fade
      },
      enabled: true,
    },
    {
      functorId: 'tile',
      instanceId: 'tile-1',
      params: { countX: 3, countY: 3 },
      enabled: true,
    },
  ],

  domain: {
    cards: [{
      cardId: 'rotate',
      instanceId: 'rotate-1',
      params: { speed: 0.5, centerX: 0.5, centerY: 0.5 },
      enabled: true,
    }],
  },

  structure: {
    cards: [{
      cardId: 'circle-sdf',
      instanceId: 'circle-1',
      params: { radius: 0.3, centerX: 0.5, centerY: 0.5, softness: 0.02 },
      enabled: true,
    }],
  },

  codomain: {
    cards: [{
      cardId: 'rainbow',
      instanceId: 'rainbow-1',
      params: { offset: 'time * 0.1', cycles: 1.0 },
      enabled: true,
    }],
  },

  settings: { resolution: { width: 512, height: 512 } },
};
```

**Generated WGSL**:

```wgsl
// ═══════════════════════════════════════════════════════════════
// Stacked Functors: Feedback over Tile
// Feedback(Tile(Rotate → Circle → Rainbow))
// ═══════════════════════════════════════════════════════════════

struct Uniforms {
  time: f32,
  resolution: vec2f,
}
@group(0) @binding(0) var<uniform> u: Uniforms;

// Feedback functor resources
@group(0) @binding(1) var feedbackTex: texture_2d<f32>;
@group(0) @binding(2) var feedbackSampler: sampler;

const PI: f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;

// ─── Lygia: Circle SDF ────────────────────────────────────────
fn circleSDF(p: vec2f, r: f32) -> f32 {
  return length(p) - r;
}

// ─── Lygia: Spectral Palette ──────────────────────────────────
fn spectral(t: f32) -> vec3f {
  return clamp(abs(fract(t + vec3f(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0) - 1.0,
               vec3f(0.0), vec3f(1.0));
}

// ─── Rotate UV Transform ──────────────────────────────────────
fn rotate(uv: vec2f, angle: f32, center: vec2f) -> vec2f {
  let centered = uv - center;
  let c = cos(angle);
  let s = sin(angle);
  return vec2f(
    centered.x * c - centered.y * s,
    centered.x * s + centered.y * c
  ) + center;
}

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  var uv = pos.xy / u.resolution;
  uv.y = 1.0 - uv.y;
  let time = u.time;

  // ═══ FUNCTOR 1: Feedback (outer) - sample previous frame ════
  let prevColor = textureSample(feedbackTex, feedbackSampler, uv).rgb;
  let fadeColor = vec3f(0.02, 0.0, 0.05);

  // ═══ FUNCTOR 2: Tile 3×3 (inner) ════════════════════════════
  let tiledUV = fract(uv * vec2f(3.0, 3.0));

  // ─── DOMAIN: Rotate ─────────────────────────────────────────
  let rotatedUV = rotate(tiledUV, time * 0.5, vec2f(0.5, 0.5));

  // ─── STRUCTURE: Circle SDF ──────────────────────────────────
  let dist = circleSDF(rotatedUV - vec2f(0.5, 0.5), 0.3);
  let value = 1.0 - smoothstep(0.0, 0.02, dist);

  // ─── CODOMAIN: Rainbow ──────────────────────────────────────
  let hueOffset = time * 0.1;
  let innerColor = spectral(value + hueOffset) * value;

  // ═══ FUNCTOR 1: Feedback - blend with previous ══════════════
  let fadedPrev = mix(prevColor, fadeColor, 0.08);  // Fade toward purple
  let result = max(innerColor, fadedPrev * 0.92);   // Additive-ish blend

  return vec4f(result, 1.0);
}
```

**Visual Result**: A 3×3 grid of rotating circles with rainbow colors. Each
circle leaves a purple-tinted trail as it rotates, creating a hypnotic pattern
where 9 spinning circles leave persistent ghostly traces.

**Key Concepts Demonstrated**:

| Concept | How It's Shown |
|---------|----------------|
| **Stacked functors** | Feedback wraps Tile wraps inner composition |
| **Order matters** | Feedback samples full UV, Tile only affects inner |
| **Functor array** | `functors: [feedback, tile]` - outer first |
| **Resource injection** | Feedback adds texture bindings automatically |
| **Independent params** | Each functor has its own configuration |

**Categorical Interpretation**:

```
Stacking is functor composition:

Feedback : Shader → Shader
Tile     : Shader → Shader

(Feedback ∘ Tile) : Shader → Shader

Given inner composition:
  inner = rainbow ∘ circle ∘ rotate : UV → Color

Applied:
  (Feedback ∘ Tile)(inner)
  = Feedback(Tile(inner))
  = Feedback(Tile(rainbow ∘ circle ∘ rotate))

Evaluation order (inside-out):
  1. UV comes in
  2. Feedback samples prevColor at UV (outer sees original UV)
  3. Tile transforms: tiledUV = fract(UV * 3)
  4. Inner runs with tiledUV
  5. Feedback blends result with prevColor
```

**Order Comparison**:

| `Feedback(Tile(inner))` | `Tile(Feedback(inner))` |
|-------------------------|-------------------------|
| Feedback sees full canvas | Feedback sees one tile |
| Trails span entire screen | Trails confined to each tile |
| 9 circles, 1 trail buffer | 9 independent trail buffers |
| **This example** | Different effect entirely |

**Why Order Matters** (Visual):

```
Feedback(Tile(inner)):          Tile(Feedback(inner)):
┌─────────────────────┐         ┌─────────────────────┐
│ ╭─╮ ╭─╮ ╭─╮        │         │ ╭─╮ │ ╭─╮ │ ╭─╮    │
│ │●│→│●│→│●│ trails │         │ │●│→│ │●│→│ │●│→│  │
│ ╰─╯ ╰─╯ ╰─╯ cross  │         │ ╰─╯ │ ╰─╯ │ ╰─╯    │
│ ╭─╮ ╭─╮ ╭─╮ tile   │         │─────┼─────┼─────   │
│ │●│→│●│→│●│ bounds │         │ ╭─╮ │ ╭─╮ │ ╭─╮    │
│ ╰─╯ ╰─╯ ╰─╯        │         │ │●│→│ │●│→│ │●│→│  │
│ ╭─╮ ╭─╮ ╭─╮        │         │ ╰─╯ │ ╰─╯ │ ╰─╯    │
│ │●│→│●│→│●│        │         │ trails stay in tile│
│ ╰─╯ ╰─╯ ╰─╯        │         │                     │
└─────────────────────┘         └─────────────────────┘
```

---

### 13.5 Sum Combinator: Day/Night Landscape

Demonstrates the **Sum (⊕)** combinator which provides choice-based composition.
A selector card determines how to blend between two alternatives. This creates
a landscape that transitions between day and night based on horizontal position.

**Visual Layout**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   DOMAIN              STRUCTURE              CODOMAIN                       │
│   (UV → UV)           (UV → Value)           (Value → Color)                │
│                                                                             │
│   ┌───────────┐       ┌───────────┐          ┌─────────────────────────┐   │
│   │ (empty)   │       │ 🏔️ FBM    │          │ ⊕ SUM (Choice)          │   │
│   │           │  ───▶ │           │   ───▶   │                         │   │
│   │           │       │ octaves:  │          │ ┌─────────────────────┐ │   │
│   │           │       │ 5         │          │ │ SELECTOR            │ │   │
│   └───────────┘       └───────────┘          │ │ ┌─────────────────┐ │ │   │
│                                              │ │ │ 🌊 Gradient     │ │ │   │
│                                              │ │ │ horizontal      │ │ │   │
│                                              │ │ └─────────────────┘ │ │   │
│                                              │ │         │ (0-1)     │ │   │
│                                              │ │   ┌─────┴─────┐     │ │   │
│                                              │ │ ┌─▼───┐   ┌───▼─┐   │ │   │
│                                              │ │ │ ☀️  │   │ 🌙  │   │ │   │
│                                              │ │ │Day  │   │Night│   │ │   │
│                                              │ └─┴─────┴───┴─────┴───┘ │   │
│                                              └─────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Data Flow**:

```
                                                    ┌───────────┐
                                              ┌────▶│ Gradient  │────┐
                                              │     │ (UV.x)    │    │ selector
                                              │     └───────────┘    │ (0-1)
UV ───▶ (identity) ───▶ FBM ───▶ value ───────┤                      │
                                              │     ┌───────────┐    │
                                              │  ┌─▶│ ☀️ Day    │◀───┤ left (t=0)
                                              │  │  │ palette   │    │
                                              │  │  └───────────┘    │
                                              └──┤                   ├───▶ mix() ───▶ Color
                                                 │  ┌───────────┐    │
                                                 └─▶│ 🌙 Night  │◀───┘ right (t=1)
                                                    │ palette   │
                                                    └───────────┘

Type: (f ⊕_s g)(value) = mix(f(value), g(value), s(uv))
```

**Composition Graph**:

```typescript
const dayNightLandscape: CompositionGraph = {
  functors: [],

  domain: {
    cards: [],  // Identity - UV passes through unchanged
  },

  structure: {
    cards: [{
      cardId: 'fbm',
      instanceId: 'fbm-1',
      params: { octaves: 5, lacunarity: 2.0, gain: 0.5, scale: 2.0 },
      enabled: true,
    }],
  },

  codomain: {
    cards: [{
      cardId: 'sum',  // ⊕ Combinator
      instanceId: 'sum-1',
      params: {},
      slots: {
        selector: {
          cardId: 'gradient-h',
          instanceId: 'gradient-selector',
          params: { smoothness: 0.3 },  // Soft transition zone
          enabled: true,
        },
        left: {
          cardId: 'palette-day',
          instanceId: 'day-palette',
          params: {
            sky: [0.53, 0.81, 0.92],      // Light blue
            horizon: [0.99, 0.95, 0.78],   // Warm yellow
            ground: [0.36, 0.54, 0.26],    // Green
          },
          enabled: true,
        },
        right: {
          cardId: 'palette-night',
          instanceId: 'night-palette',
          params: {
            sky: [0.05, 0.05, 0.15],      // Dark blue
            horizon: [0.15, 0.10, 0.20],   // Purple
            ground: [0.08, 0.12, 0.08],    // Dark green
          },
          enabled: true,
        },
      },
      enabled: true,
    }],
  },

  settings: { resolution: { width: 512, height: 512 } },
};
```

**Generated WGSL**:

```wgsl
// ═══════════════════════════════════════════════════════════════
// Sum Combinator: Day/Night Landscape
// Uses ⊕ to blend between day and night palettes based on UV.x
// ═══════════════════════════════════════════════════════════════

struct Uniforms {
  time: f32,
  resolution: vec2f,
}
@group(0) @binding(0) var<uniform> u: Uniforms;

// ─── Lygia: Simplex Noise (for FBM) ───────────────────────────
fn mod289(x: vec3f) -> vec3f { return x - floor(x * (1.0/289.0)) * 289.0; }
fn mod289_4(x: vec4f) -> vec4f { return x - floor(x * (1.0/289.0)) * 289.0; }
fn permute(x: vec4f) -> vec4f { return mod289_4(((x * 34.0) + 1.0) * x); }
fn taylorInvSqrt(r: vec4f) -> vec4f { return 1.79284291400159 - 0.85373472095314 * r; }

fn snoise(v: vec2f) -> f32 {
  let C = vec4f(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
  var i = floor(v + dot(v, C.yy));
  let x0 = v - i + dot(i, C.xx);
  var i1 = select(vec2f(0.0, 1.0), vec2f(1.0, 0.0), x0.x > x0.y);
  var x12 = x0.xyxy + C.xxzz;
  x12 = vec4f(x12.xy - i1, x12.zw);
  i = mod289(i.xyxy).xy;
  let p = permute(permute(i.y + vec4f(0.0, i1.y, 1.0, 0.0)) + i.x + vec4f(0.0, i1.x, 1.0, 0.0));
  var m = max(0.5 - vec4f(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw), 0.0), vec4f(0.0));
  m = m * m;
  m = m * m;
  let x = 2.0 * fract(p * C.wwww) - 1.0;
  let h = abs(x) - 0.5;
  let ox = floor(x + 0.5);
  let a0 = x - ox;
  m *= taylorInvSqrt(a0 * a0 + h * h);
  let g = vec3f(a0.x * x0.x + h.x * x0.y, a0.yz * x12.xz + h.yz * x12.yw);
  return 130.0 * dot(m.xyz, g);
}

// ─── FBM ──────────────────────────────────────────────────────
fn fbm(p: vec2f, octaves: i32) -> f32 {
  var value = 0.0;
  var amplitude = 0.5;
  var frequency = 1.0;
  for (var i = 0; i < octaves; i++) {
    value += amplitude * snoise(p * frequency);
    frequency *= 2.0;
    amplitude *= 0.5;
  }
  return value * 0.5 + 0.5;
}

// ─── Day Palette ──────────────────────────────────────────────
fn dayPalette(t: f32) -> vec3f {
  let sky = vec3f(0.53, 0.81, 0.92);
  let horizon = vec3f(0.99, 0.95, 0.78);
  let ground = vec3f(0.36, 0.54, 0.26);

  if (t < 0.4) {
    return mix(ground, horizon, t / 0.4);
  } else {
    return mix(horizon, sky, (t - 0.4) / 0.6);
  }
}

// ─── Night Palette ────────────────────────────────────────────
fn nightPalette(t: f32) -> vec3f {
  let sky = vec3f(0.05, 0.05, 0.15);
  let horizon = vec3f(0.15, 0.10, 0.20);
  let ground = vec3f(0.08, 0.12, 0.08);

  if (t < 0.4) {
    return mix(ground, horizon, t / 0.4);
  } else {
    return mix(horizon, sky, (t - 0.4) / 0.6);
  }
}

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  var uv = pos.xy / u.resolution;
  uv.y = 1.0 - uv.y;
  let time = u.time;

  // ─── DOMAIN: Identity (no transformation) ───────────────────

  // ─── STRUCTURE: FBM terrain height ──────────────────────────
  let terrain = fbm(uv * 2.0 + vec2f(time * 0.05, 0.0), 5);
  // Create horizon line with terrain
  let height = uv.y + (terrain - 0.5) * 0.3;
  let value = smoothstep(0.3, 0.7, height);

  // ─── CODOMAIN: Sum (Day ⊕ Night) ────────────────────────────
  // Selector: horizontal gradient with soft edge
  let selector = smoothstep(0.35, 0.65, uv.x);

  // Left slot: Day palette
  let dayColor = dayPalette(value);

  // Right slot: Night palette
  let nightColor = nightPalette(value);

  // Sum combinator: mix based on selector
  let color = mix(dayColor, nightColor, selector);

  // Add stars in night portion
  let starNoise = snoise(uv * 100.0);
  let stars = step(0.98, starNoise) * selector * step(0.6, value);
  let finalColor = color + vec3f(stars);

  return vec4f(finalColor, 1.0);
}
```

**Visual Result**: A procedural landscape where the left side shows a sunny day
scene (blue sky, warm horizon, green ground) and the right side shows night
(dark blue sky with stars, purple horizon, dark ground). The transition is
smooth, controlled by the horizontal gradient selector.

**Key Concepts Demonstrated**:

| Concept | How It's Shown |
|---------|----------------|
| **Sum (⊕)** | Blends between two color palettes |
| **Selector slot** | Horizontal gradient determines day/night mix |
| **Left/Right slots** | Day and Night palettes as alternatives |
| **Choice semantics** | `selector=0` → day, `selector=1` → night |
| **Smooth transition** | `smoothstep` in selector creates soft blend zone |

**Categorical Interpretation**:

```
⊕ : (Value → Color) × (Value → Color) × (UV → Value) → (Value → Color)

Given:
  day    : Value → Color   (left slot)
  night  : Value → Color   (right slot)
  grad   : UV → Value      (selector: uv.x with smoothstep)

Sum creates:
  (day ⊕_grad night) : Value → Color

  (day ⊕_grad night)(v, uv) = mix(day(v), night(v), grad(uv))

This is a parameterized coproduct in the enriched category,
where the selector provides the "case analysis" function.
```

**Comparison: Sum vs Product**:

| Product (⊗) | Sum (⊕) |
|-------------|---------|
| Both slots always execute | Both slots always execute |
| Results combined (multiply, add, etc.) | Results blended by selector |
| `f ⊗ g = combine(f(x), g(x))` | `f ⊕_s g = mix(f(x), g(x), s(x))` |
| Good for: masks, layering | Good for: transitions, choices |
| Example: noise masked by circle | Example: day/night blend |

**Alternative Selectors**:

| Selector | Effect |
|----------|--------|
| `uv.x` | Left-to-right transition |
| `uv.y` | Bottom-to-top transition |
| `length(uv - 0.5)` | Radial transition (center to edge) |
| `sin(time)` | Animated oscillation |
| `noise(uv)` | Organic, patchy transition |
| `step(0.5, uv.x)` | Hard split (no blend) |

---

### 13.6 Fix Combinator: Fractal Spiral Tree

Demonstrates the **Fix (μ)** combinator for recursive/iterative composition.
The body references `{self}` which gets unrolled at compile time, creating
fractal patterns through bounded iteration.

**Visual Layout**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   DOMAIN              STRUCTURE                          CODOMAIN           │
│   (UV → UV)           (UV → Value)                       (Value → Color)    │
│                                                                             │
│   ┌───────────┐       ┌─────────────────────────────┐    ┌───────────┐     │
│   │ 🔄 Polar  │       │ μ FIX (Recursion)           │    │ 🌲 Forest │     │
│   │           │       │ iterations: 6               │    │  Palette  │     │
│   │ center:   │  ───▶ │                             │───▶│           │     │
│   │ (0.5,0.5) │       │  ┌───────────────────────┐  │    │           │     │
│   └───────────┘       │  │ BODY (uses {self})    │  │    └───────────┘     │
│                       │  │                       │  │                       │
│                       │  │ scale(0.7) >>>        │  │                       │
│                       │  │ rotate(25°) >>>       │  │                       │
│                       │  │ translate(0, -0.2) >>>│  │                       │
│                       │  │ max(branch, {self})   │  │                       │
│                       │  │        ▲              │  │                       │
│                       │  │        │              │  │                       │
│                       │  │   ┌────┴────┐         │  │                       │
│                       │  │   │  SELF   │◀────────┼──┤                       │
│                       │  │   │(recurse)│         │  │                       │
│                       │  │   └─────────┘         │  │                       │
│                       │  └───────────────────────┘  │                       │
│                       └─────────────────────────────┘                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Data Flow**:

```
                        ┌─────────────────────────────────────────────────────┐
                        │  μ Fix (iterations=6)                               │
                        │                                                     │
                        │  Unrolling:                                         │
                        │    iter 0: branch(uv)                               │
UV ───▶ Polar ───▶ UV' ─┤    iter 1: max(branch(T(uv)), iter0)               │───▶ Forest ───▶ Color
                        │    iter 2: max(branch(T(T(uv))), iter1)            │     Palette
                        │    iter 3: max(branch(T³(uv)), iter2)              │
                        │    ...                                              │
                        │    iter 5: max(branch(T⁵(uv)), iter4)              │
                        │                                                     │
                        │  where T = scale(0.7) ∘ rotate(25°) ∘ translate    │
                        └─────────────────────────────────────────────────────┘

Type: fix(f) : UV → Value  where f uses {self} : Value
```

**Composition Graph**:

```typescript
const fractalSpiralTree: CompositionGraph = {
  functors: [],

  domain: {
    cards: [{
      cardId: 'polar',
      instanceId: 'polar-1',
      params: { centerX: 0.5, centerY: 0.8 },  // Base of tree
      enabled: true,
    }],
  },

  structure: {
    cards: [{
      cardId: 'fix',  // μ Combinator
      instanceId: 'fix-1',
      params: {
        iterations: 6,
        baseValue: 0.0,
      },
      slots: {
        body: {
          // The body is a Pipe of transformations ending in blend with {self}
          cardId: 'pipe',
          instanceId: 'body-pipe',
          slots: {
            stages: [
              {
                cardId: 'uv-transform',
                instanceId: 'transform-1',
                params: {
                  scale: 0.7,
                  rotate: 25,           // degrees
                  translateY: -0.15,    // Move up
                },
                enabled: true,
              },
              {
                cardId: 'branch-sdf',
                instanceId: 'branch-1',
                params: {
                  width: 0.08,
                  height: 0.3,
                  taper: 0.6,
                },
                enabled: true,
              },
              {
                cardId: 'max-blend',
                instanceId: 'max-1',
                params: {},
                slots: {
                  left: '{current}',    // Current branch
                  right: '{self}',      // Recursive reference
                },
                enabled: true,
              },
            ],
          },
          enabled: true,
        },
      },
      enabled: true,
    }],
  },

  codomain: {
    cards: [{
      cardId: 'palette-forest',
      instanceId: 'forest-1',
      params: {
        trunk: [0.36, 0.25, 0.15],    // Brown
        branch: [0.28, 0.20, 0.12],   // Darker brown
        leaves: [0.18, 0.42, 0.14],   // Green
        sky: [0.70, 0.85, 0.95],      // Light blue
      },
      enabled: true,
    }],
  },

  settings: { resolution: { width: 512, height: 512 } },
};
```

**Generated WGSL**:

```wgsl
// ═══════════════════════════════════════════════════════════════
// Fix Combinator: Fractal Spiral Tree
// Uses μ (fix) for bounded recursion via loop unrolling
// ═══════════════════════════════════════════════════════════════

struct Uniforms {
  time: f32,
  resolution: vec2f,
}
@group(0) @binding(0) var<uniform> u: Uniforms;

const PI: f32 = 3.14159265359;
const DEG_TO_RAD: f32 = PI / 180.0;

// ─── Branch SDF ───────────────────────────────────────────────
fn branchSDF(p: vec2f, width: f32, height: f32, taper: f32) -> f32 {
  // Tapered rectangle (trapezoid) for branch shape
  let taperFactor = mix(1.0, taper, (p.y + height) / (height * 2.0));
  let w = width * taperFactor;

  let d = vec2f(abs(p.x) - w, abs(p.y) - height);
  return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0);
}

// ─── UV Transform ─────────────────────────────────────────────
fn transformUV(uv: vec2f, scale: f32, rotateDeg: f32, translate: vec2f) -> vec2f {
  var p = uv;

  // Translate
  p = p - translate;

  // Scale from origin
  p = p / scale;

  // Rotate
  let angle = rotateDeg * DEG_TO_RAD;
  let c = cos(angle);
  let s = sin(angle);
  p = vec2f(p.x * c - p.y * s, p.x * s + p.y * c);

  return p;
}

// ─── Forest Palette ───────────────────────────────────────────
fn forestPalette(dist: f32, height: f32) -> vec3f {
  let trunk = vec3f(0.36, 0.25, 0.15);
  let branch = vec3f(0.28, 0.20, 0.12);
  let leaves = vec3f(0.18, 0.42, 0.14);
  let sky = vec3f(0.70, 0.85, 0.95);

  // Inside tree
  if (dist < 0.0) {
    // Gradient from trunk to leaves based on height
    let t = smoothstep(-0.5, 0.5, height);
    return mix(trunk, leaves, t);
  }

  // Outside - sky with soft edge
  let edge = smoothstep(0.0, 0.02, dist);
  return mix(branch, sky, edge);
}

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  var uv = pos.xy / u.resolution;
  uv.y = 1.0 - uv.y;
  let time = u.time;

  // ─── DOMAIN: Center at base of tree ─────────────────────────
  var p = uv - vec2f(0.5, 0.8);
  p.y = -p.y;  // Flip so tree grows upward

  // ═══ STRUCTURE: Fix (unrolled recursion) ════════════════════
  // Base case
  var result = 1000.0;  // Large distance = outside
  var currentP = p;
  var currentHeight = 0.0;

  // Transform parameters
  let scaleFactor = 0.7;
  let rotateAngle = 25.0 + sin(time * 0.5) * 5.0;  // Slight sway
  let translateY = vec2f(0.0, -0.15);

  // ─── Iteration 0 (trunk) ────────────────────────────────────
  var branch0 = branchSDF(currentP, 0.08, 0.15, 0.7);
  result = min(result, branch0);
  var height0 = currentP.y;

  // ─── Iteration 1 ────────────────────────────────────────────
  currentP = transformUV(currentP, scaleFactor, rotateAngle, translateY);
  var branch1 = branchSDF(currentP, 0.08, 0.15, 0.7);
  result = min(result, branch1);

  // Mirror branch (bilateral symmetry)
  var mirrorP1 = transformUV(p, scaleFactor, -rotateAngle, translateY);
  result = min(result, branchSDF(mirrorP1, 0.08, 0.15, 0.7));

  // ─── Iteration 2 ────────────────────────────────────────────
  currentP = transformUV(currentP, scaleFactor, rotateAngle, translateY);
  result = min(result, branchSDF(currentP, 0.08, 0.15, 0.7));

  mirrorP1 = transformUV(mirrorP1, scaleFactor, -rotateAngle, translateY);
  result = min(result, branchSDF(mirrorP1, 0.08, 0.15, 0.7));

  // ─── Iteration 3 ────────────────────────────────────────────
  currentP = transformUV(currentP, scaleFactor, rotateAngle, translateY);
  result = min(result, branchSDF(currentP, 0.06, 0.12, 0.7));

  mirrorP1 = transformUV(mirrorP1, scaleFactor, -rotateAngle, translateY);
  result = min(result, branchSDF(mirrorP1, 0.06, 0.12, 0.7));

  // ─── Iteration 4 ────────────────────────────────────────────
  currentP = transformUV(currentP, scaleFactor, rotateAngle, translateY);
  result = min(result, branchSDF(currentP, 0.04, 0.10, 0.7));

  mirrorP1 = transformUV(mirrorP1, scaleFactor, -rotateAngle, translateY);
  result = min(result, branchSDF(mirrorP1, 0.04, 0.10, 0.7));

  // ─── Iteration 5 (leaves) ───────────────────────────────────
  currentP = transformUV(currentP, scaleFactor, rotateAngle, translateY);
  result = min(result, branchSDF(currentP, 0.03, 0.08, 0.8));

  mirrorP1 = transformUV(mirrorP1, scaleFactor, -rotateAngle, translateY);
  result = min(result, branchSDF(mirrorP1, 0.03, 0.08, 0.8));

  // Track height for coloring
  let treeHeight = 1.0 - (result + 0.5);

  // ─── CODOMAIN: Forest Palette ───────────────────────────────
  let color = forestPalette(result, treeHeight);

  return vec4f(color, 1.0);
}
```

**Visual Result**: A procedural fractal tree with trunk, branches, and implied
foliage. The tree exhibits self-similarity as each branch spawns smaller rotated
copies. The branches sway gently with time, and colors transition from brown
trunk to green leaves.

**Key Concepts Demonstrated**:

| Concept | How It's Shown |
|---------|----------------|
| **Fix (μ)** | Body references `{self}` for recursion |
| **Loop unrolling** | Compiler expands iterations at compile time |
| **Bounded recursion** | `iterations: 6` prevents infinite loops |
| **Self-similarity** | Each iteration applies same transform |
| **Accumulation** | `min(branch, {self})` unions all branches |

**Categorical Interpretation**:

```
μ : ((A → B) × (B → B)) → (A → B)

Given:
  base   : A → B           (initial branch at trunk)
  step   : B → B           (transform + add branch + union)

Fix creates:
  fix(step, base) : A → B

  fix(step, base) = step⁶(base)  -- 6 iterations
                  = step(step(step(step(step(step(base))))))

In our tree:
  base = branchSDF(p)
  step = λself. min(branchSDF(T(p)), self)

  where T = scale ∘ rotate ∘ translate

This is a finite approximation of the categorical fixed point:
  μX. F(X) ≈ F(F(F(F(F(F(⊥))))))
```

**Unrolling Visualization**:

```
Iteration 0:  trunk
              │
              ╧

Iteration 1:  trunk + 2 branches
              ╱│╲
              ╧

Iteration 2:  + 4 sub-branches
             ╱╱│╲╲
              ╱│╲
              ╧

Iteration 5:  Full tree
           ╱╱╱╱│╲╲╲╲
          ╱╱╱ │ ╲╲╲
           ╱╱│╲╲
            ╱│╲
             │
             ╧
```

**Fix vs Other Combinators**:

| Combinator | Pattern | Use Case |
|------------|---------|----------|
| **Pipe (>>>)** | Sequential | f >>> g >>> h |
| **Product (⊗)** | Parallel + merge | f ⊗ g |
| **Sum (⊕)** | Choice by selector | f ⊕_s g |
| **Fix (μ)** | **Iteration/recursion** | **μf = f(f(f(...)))** |

**Alternative Fix Patterns**:

| Pattern | Body | Result |
|---------|------|--------|
| Fractal tree | `min(branch, T({self}))` | Branching structure |
| Fractal noise | `noise + 0.5 * T({self})` | FBM-like layers |
| Spiral | `rotate(θ) ∘ scale(s) ∘ {self}` | Logarithmic spiral |
| Koch curve | `segment ∪ T₁({self}) ∪ T₂({self})` | Snowflake |
| Mandelbrot | `z² + c` with `{self}` as z | Classic fractal |

---

### 13.7 Pipe Combinator: Neon Glow Text Effect

Demonstrates the **Pipe (>>>)** combinator for sequential composition. Each
stage transforms the output of the previous, creating a multi-step post-processing
pipeline. This example builds a neon glow effect through chained operations.

**Visual Layout**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   DOMAIN              STRUCTURE              CODOMAIN                       │
│   (UV → UV)           (UV → Value)           (Value → Color)                │
│                                                                             │
│   ┌───────────┐       ┌───────────┐          ┌─────────────────────────┐   │
│   │ (empty)   │       │ 📝 Text   │          │ ▷ PIPE (>>>)            │   │
│   │           │  ───▶ │   SDF     │   ───▶   │                         │   │
│   │           │       │           │          │ ┌───────┐   ┌───────┐   │   │
│   │           │       │ "NEON"    │          │ │Invert │──▶│ Glow  │   │   │
│   └───────────┘       └───────────┘          │ │       │   │       │   │   │
│                                              │ └───────┘   └───┬───┘   │   │
│                                              │                 │       │   │
│                                              │                 ▼       │   │
│                                              │           ┌───────┐     │   │
│                                              │           │Saturate──▶  │   │
│                                              │           │       │     │   │
│                                              │           └───┬───┘     │   │
│                                              │               │         │   │
│                                              │               ▼         │   │
│                                              │         ┌───────┐       │   │
│                                              │         │ Neon  │───▶   │   │
│                                              │         │Palette│       │   │
│                                              │         └───────┘       │   │
│                                              └─────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Data Flow**:

```
                                   ┌─────────────────────────────────────────────────────┐
                                   │  ▷ Pipe (>>>)                                       │
                                   │                                                     │
UV ───▶ (identity) ───▶ TextSDF ──▶│  Invert ───▶ Glow ───▶ Saturate ───▶ NeonPalette  │───▶ Color
                          │        │    │          │           │              │          │
                          │        │    │          │           │              │          │
                        Value      │  Value     Value       Value          Color        │
                        (dist)     │  (1-d)     (bloom)    (clamped)      (final)       │
                                   └─────────────────────────────────────────────────────┘

Type chain:  Value ─Invert─▶ Value ─Glow─▶ Value ─Saturate─▶ Value ─Palette─▶ Color
             (A → A)         (A → A)        (A → A)           (A → B)
```

**Composition Graph**:

```typescript
const neonGlowText: CompositionGraph = {
  functors: [],

  domain: {
    cards: [],  // Identity
  },

  structure: {
    cards: [{
      cardId: 'text-sdf',
      instanceId: 'text-1',
      params: {
        text: 'NEON',
        font: 'bold',
        size: 0.3,
        centerX: 0.5,
        centerY: 0.5,
      },
      enabled: true,
    }],
  },

  codomain: {
    cards: [{
      cardId: 'pipe',  // >>> Combinator
      instanceId: 'pipe-1',
      params: {},
      slots: {
        stages: [
          {
            cardId: 'invert',
            instanceId: 'invert-1',
            params: {},  // output = 1.0 - input
            enabled: true,
          },
          {
            cardId: 'glow',
            instanceId: 'glow-1',
            params: {
              intensity: 2.5,
              falloff: 3.0,
              radius: 0.15,
            },
            enabled: true,
          },
          {
            cardId: 'saturate',
            instanceId: 'saturate-1',
            params: {
              min: 0.0,
              max: 1.0,
            },
            enabled: true,
          },
          {
            cardId: 'palette-neon',
            instanceId: 'neon-1',
            params: {
              background: [0.02, 0.02, 0.05],  // Near black
              glow: [1.0, 0.2, 0.8],           // Hot pink
              core: [1.0, 1.0, 1.0],           // White hot center
              pulseSpeed: 2.0,
            },
            enabled: true,
          },
        ],
      },
      enabled: true,
    }],
  },

  settings: { resolution: { width: 512, height: 512 } },
};
```

**Generated WGSL**:

```wgsl
// ═══════════════════════════════════════════════════════════════
// Pipe Combinator: Neon Glow Text Effect
// Uses >>> for sequential post-processing chain
// ═══════════════════════════════════════════════════════════════

struct Uniforms {
  time: f32,
  resolution: vec2f,
}
@group(0) @binding(0) var<uniform> u: Uniforms;

// ─── Simple Box SDF for letters ───────────────────────────────
fn boxSDF(p: vec2f, size: vec2f) -> f32 {
  let d = abs(p) - size;
  return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0);
}

// ─── Simplified "NEON" text SDF ───────────────────────────────
fn textSDF(p: vec2f) -> f32 {
  var d = 1000.0;
  let letterSpacing = 0.22;
  let letterWidth = 0.08;
  let letterHeight = 0.15;

  // N
  var lp = p - vec2f(-0.33, 0.0);
  d = min(d, boxSDF(lp - vec2f(-letterWidth, 0.0), vec2f(0.02, letterHeight)));  // Left
  d = min(d, boxSDF(lp - vec2f(letterWidth, 0.0), vec2f(0.02, letterHeight)));   // Right
  d = min(d, boxSDF(lp, vec2f(letterWidth, 0.02)));  // Diagonal approx

  // E
  lp = p - vec2f(-0.11, 0.0);
  d = min(d, boxSDF(lp - vec2f(-0.04, 0.0), vec2f(0.02, letterHeight)));         // Spine
  d = min(d, boxSDF(lp - vec2f(0.02, letterHeight - 0.02), vec2f(0.06, 0.02)));  // Top
  d = min(d, boxSDF(lp - vec2f(0.02, 0.0), vec2f(0.05, 0.02)));                  // Mid
  d = min(d, boxSDF(lp - vec2f(0.02, -letterHeight + 0.02), vec2f(0.06, 0.02))); // Bot

  // O
  lp = p - vec2f(0.11, 0.0);
  let outerO = length(lp) - 0.12;
  let innerO = length(lp) - 0.08;
  d = min(d, max(outerO, -innerO));

  // N (second)
  lp = p - vec2f(0.33, 0.0);
  d = min(d, boxSDF(lp - vec2f(-letterWidth, 0.0), vec2f(0.02, letterHeight)));
  d = min(d, boxSDF(lp - vec2f(letterWidth, 0.0), vec2f(0.02, letterHeight)));
  d = min(d, boxSDF(lp, vec2f(letterWidth, 0.02)));

  return d;
}

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  var uv = pos.xy / u.resolution;
  uv.y = 1.0 - uv.y;
  let time = u.time;

  // Center UV
  let aspect = u.resolution.x / u.resolution.y;
  var p = uv - 0.5;
  p.x *= aspect;

  // ─── STRUCTURE: Text SDF ────────────────────────────────────
  let dist = textSDF(p);

  // ═══ CODOMAIN: Pipe (>>> sequential chain) ══════════════════

  // ─── Stage 1: Invert ────────────────────────────────────────
  // Convert distance (positive outside) to intensity (positive inside)
  let inverted = 1.0 - dist;

  // ─── Stage 2: Glow ──────────────────────────────────────────
  // Exponential falloff creates bloom effect
  let glowIntensity = 2.5;
  let glowFalloff = 3.0;
  let glowRadius = 0.15;
  let glow = glowIntensity * exp(-glowFalloff * max(dist, 0.0) / glowRadius);

  // Add pulsing
  let pulse = 0.8 + 0.2 * sin(time * 2.0);
  let glowPulsed = glow * pulse;

  // ─── Stage 3: Saturate ──────────────────────────────────────
  // Clamp to valid range
  let saturated = clamp(glowPulsed, 0.0, 1.0);

  // ─── Stage 4: Neon Palette ──────────────────────────────────
  let background = vec3f(0.02, 0.02, 0.05);
  let glowColor = vec3f(1.0, 0.2, 0.8);   // Hot pink
  let coreColor = vec3f(1.0, 1.0, 1.0);   // White

  // Core is white, glow is pink, background is dark
  var color = background;

  // Add glow halo
  color = mix(color, glowColor, saturated * 0.8);

  // Add bright core where inside text
  let core = smoothstep(0.01, -0.01, dist);
  color = mix(color, coreColor, core);

  // Extra bloom layer (subtle outer glow)
  let outerGlow = exp(-1.5 * max(dist, 0.0) / 0.3);
  color += glowColor * outerGlow * 0.15 * pulse;

  return vec4f(color, 1.0);
}
```

**Visual Result**: The word "NEON" rendered with a classic neon sign effect -
white-hot letter cores, pink glow halo, subtle bloom, and gentle pulsing
animation against a dark background.

**Key Concepts Demonstrated**:

| Concept | How It's Shown |
|---------|----------------|
| **Pipe (>>>)** | Four stages chained sequentially |
| **Type threading** | Value → Value → Value → Value → Color |
| **Order matters** | Invert before Glow, Saturate before Palette |
| **Stage slots** | Array of cards in execution order |
| **Post-processing** | Classic effect pipeline pattern |

**Categorical Interpretation**:

```
>>> : (A → B) × (B → C) → (A → C)

Given stages:
  invert   : Value → Value
  glow     : Value → Value
  saturate : Value → Value
  palette  : Value → Color

Pipe creates:
  (invert >>> glow >>> saturate >>> palette) : Value → Color

This is exactly morphism composition in the category:
  palette ∘ saturate ∘ glow ∘ invert

Associativity: (f >>> g) >>> h = f >>> (g >>> h)
Identity: id >>> f = f = f >>> id
```

**Pipeline Visualization**:

```
Input (dist)
    │
    ▼
┌─────────┐
│ Invert  │  1.0 - dist
└────┬────┘
     │
     ▼
┌─────────┐
│  Glow   │  intensity * exp(-falloff * dist / radius)
└────┬────┘
     │
     ▼
┌─────────┐
│Saturate │  clamp(value, 0.0, 1.0)
└────┬────┘
     │
     ▼
┌─────────┐
│ Palette │  mix(background, glow, core)
└────┬────┘
     │
     ▼
Output (color)
```

**Pipe vs Other Combinators**:

| Combinator | Data Flow | Type Signature |
|------------|-----------|----------------|
| **Pipe (>>>)** | **Serial: A → B → C** | **(A→B) × (B→C) → (A→C)** |
| Product (⊗) | Parallel: A → (B, B) → B | (A→B) × (A→B) → (A→B) |
| Sum (⊕) | Choice: A → B or B | (A→B) × (A→B) × (A→V) → (A→B) |
| Fix (μ) | Loop: A → A → A → ... | ((A→A) → (A→A)) |

**Common Pipe Patterns**:

| Pattern | Stages | Use Case |
|---------|--------|----------|
| Post-processing | Bloom → Tonemap → Gamma | Final image adjustments |
| SDF operations | Round → Elongate → Twist | Shape manipulation |
| Color grading | Exposure → Contrast → Vibrance | Photo effects |
| Signal processing | Smooth → Threshold → Quantize | Data conditioning |
| Animation | Ease → Remap → Clamp | Motion curves |

**Extending the Pipeline**:

```typescript
// Easy to add more stages:
slots: {
  stages: [
    { cardId: 'invert', ... },
    { cardId: 'glow', ... },
    { cardId: 'chromatic-aberration', ...},  // New!
    { cardId: 'scanlines', ... },            // New!
    { cardId: 'saturate', ... },
    { cardId: 'palette-neon', ... },
  ],
}
```

---

### 13.8 Lift Combinator: Localized Mirror Effect

Demonstrates the **Lift (⇑)** combinator which applies a functor to a specific
card rather than the entire composition. This enables localized effects - here
we mirror only the Structure column while Domain and Codomain remain unaffected.

**Visual Layout**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   DOMAIN              STRUCTURE                          CODOMAIN           │
│   (UV → UV)           (UV → Value)                       (Value → Color)    │
│                                                                             │
│   ┌───────────┐       ┌─────────────────────────────┐    ┌───────────┐     │
│   │ 🌀 Swirl  │       │ ⇑ LIFT                      │    │ 🎨 Gradient│     │
│   │           │       │                             │    │  Palette  │     │
│   │ amount:   │  ───▶ │  Functor: [🪞 Mirror X+Y]  │───▶│           │     │
│   │ 0.5       │       │                             │    │ warm to   │     │
│   └───────────┘       │  ╔═════════════════════════╗│    │ cool      │     │
│                       │  ║  ┌─────────────────────┐║│    └───────────┘     │
│                       │  ║  │ Inner Card          │║│                       │
│                       │  ║  │                     │║│                       │
│                       │  ║  │  🔷 Voronoi         │║│                       │
│                       │  ║  │  scale: 5           │║│                       │
│                       │  ║  │                     │║│                       │
│                       │  ║  └─────────────────────┘║│                       │
│                       │  ╚═════════════════════════╝│                       │
│                       └─────────────────────────────┘                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Data Flow**:

```
                         Lift applies Mirror ONLY to Voronoi
                                      │
                                      ▼
              ┌───────────────────────────────────────────────────┐
              │  ⇑ Lift(Mirror, Voronoi)                         │
              │                                                   │
UV ───▶ Swirl │   mirrorUV = mirror(swirlUV)                     │───▶ Gradient ───▶ Color
         │    │        │                                          │      Palette
         │    │        ▼                                          │
         │    │   ╔═══════════════╗                               │
         │    │   ║   Voronoi     ║                               │
         ▼    │   ║   (mirrored)  ║                               │
      swirlUV │   ╚═══════════════╝                               │
              │        │                                          │
              │        ▼                                          │
              │      Value (4-way symmetric voronoi)              │
              └───────────────────────────────────────────────────┘

Key: Swirl is NOT mirrored, only Voronoi is
     Gradient receives mirrored voronoi output
```

**Composition Graph**:

```typescript
const localizedMirror: CompositionGraph = {
  functors: [],  // No composition-level functors!

  domain: {
    cards: [{
      cardId: 'swirl',
      instanceId: 'swirl-1',
      params: {
        amount: 0.5,
        centerX: 0.5,
        centerY: 0.5,
        radius: 0.4,
      },
      enabled: true,
    }],
  },

  structure: {
    cards: [{
      cardId: 'lift',  // ⇑ Combinator
      instanceId: 'lift-1',
      params: {},
      slots: {
        functor: {
          functorId: 'mirror',
          params: {
            axisX: true,
            axisY: true,
          },
        },
        inner: {
          cardId: 'voronoi',
          instanceId: 'voronoi-inner',
          params: {
            scale: 5.0,
            jitter: 1.0,
            metric: 'euclidean',
          },
          enabled: true,
        },
      },
      enabled: true,
    }],
  },

  codomain: {
    cards: [{
      cardId: 'palette-gradient',
      instanceId: 'gradient-1',
      params: {
        colorA: [0.95, 0.55, 0.25],  // Warm orange
        colorB: [0.25, 0.55, 0.85],  // Cool blue
        midpoint: 0.5,
      },
      enabled: true,
    }],
  },

  settings: { resolution: { width: 512, height: 512 } },
};
```

**Generated WGSL**:

```wgsl
// ═══════════════════════════════════════════════════════════════
// Lift Combinator: Localized Mirror Effect
// Uses ⇑ to apply Mirror functor ONLY to Voronoi card
// ═══════════════════════════════════════════════════════════════

struct Uniforms {
  time: f32,
  resolution: vec2f,
}
@group(0) @binding(0) var<uniform> u: Uniforms;

const PI: f32 = 3.14159265359;

// ─── Voronoi Distance ─────────────────────────────────────────
fn hash2(p: vec2f) -> vec2f {
  return fract(sin(vec2f(
    dot(p, vec2f(127.1, 311.7)),
    dot(p, vec2f(269.5, 183.3))
  )) * 43758.5453);
}

fn voronoi(p: vec2f, jitter: f32) -> f32 {
  let n = floor(p);
  let f = fract(p);

  var minDist = 1.0;

  for (var j = -1; j <= 1; j++) {
    for (var i = -1; i <= 1; i++) {
      let neighbor = vec2f(f32(i), f32(j));
      let point = hash2(n + neighbor) * jitter;
      let diff = neighbor + point - f;
      let dist = length(diff);
      minDist = min(minDist, dist);
    }
  }

  return minDist;
}

// ─── Swirl Transform ──────────────────────────────────────────
fn swirl(uv: vec2f, center: vec2f, amount: f32, radius: f32) -> vec2f {
  let delta = uv - center;
  let dist = length(delta);
  let angle = atan2(delta.y, delta.x);

  // Swirl strength falls off with distance
  let swirlAmount = amount * smoothstep(radius, 0.0, dist);
  let newAngle = angle + swirlAmount * (radius - dist);

  return center + vec2f(cos(newAngle), sin(newAngle)) * dist;
}

// ─── Mirror Transform ─────────────────────────────────────────
fn mirror(uv: vec2f, axisX: bool, axisY: bool) -> vec2f {
  var result = uv;
  if (axisX) { result.x = abs(result.x * 2.0 - 1.0); }
  if (axisY) { result.y = abs(result.y * 2.0 - 1.0); }
  return result;
}

// ─── Gradient Palette ─────────────────────────────────────────
fn gradientPalette(t: f32, colorA: vec3f, colorB: vec3f) -> vec3f {
  return mix(colorA, colorB, clamp(t, 0.0, 1.0));
}

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  var uv = pos.xy / u.resolution;
  uv.y = 1.0 - uv.y;
  let time = u.time;

  // ─── DOMAIN: Swirl (NOT mirrored) ───────────────────────────
  let swirlCenter = vec2f(0.5, 0.5);
  let swirlAmount = 0.5 + 0.2 * sin(time * 0.5);
  let swirlRadius = 0.4;
  let swirledUV = swirl(uv, swirlCenter, swirlAmount, swirlRadius);

  // ═══ STRUCTURE: Lift(Mirror, Voronoi) ═══════════════════════
  // The Lift combinator applies Mirror ONLY to the Voronoi card
  // swirledUV flows in, but is mirrored before Voronoi sees it

  // Functor: Mirror X and Y (creates 4-way symmetry)
  let mirroredUV = mirror(swirledUV, true, true);

  // Inner: Voronoi (sees mirrored coordinates)
  let value = voronoi(mirroredUV * 5.0, 1.0);

  // ─── CODOMAIN: Gradient Palette (NOT mirrored) ──────────────
  let colorA = vec3f(0.95, 0.55, 0.25);  // Warm orange
  let colorB = vec3f(0.25, 0.55, 0.85);  // Cool blue
  let color = gradientPalette(value, colorA, colorB);

  return vec4f(color, 1.0);
}
```

**Visual Result**: A swirling pattern with 4-way symmetric voronoi cells. The
swirl distortion is asymmetric (applied before mirror), but the voronoi pattern
itself has perfect bilateral symmetry on both axes. Colors flow from warm
orange to cool blue.

**Key Concepts Demonstrated**:

| Concept | How It's Shown |
|---------|----------------|
| **Lift (⇑)** | Applies Mirror to Voronoi only |
| **Localized effect** | Swirl and Palette are NOT mirrored |
| **Functor slot** | Mirror functor specified inline |
| **Inner slot** | Voronoi card wrapped by functor |
| **Selective transformation** | Fine-grained control over what's affected |

**Categorical Interpretation**:

```
⇑ : Functor × (A → B) → (F(A) → F(B))

Given:
  Mirror   : Functor (UV transformation)
  voronoi  : UV → Value

Lift creates:
  ⇑(Mirror, voronoi) : UV → Value

  ⇑(Mirror, voronoi)(uv) = voronoi(Mirror(uv))

This is the functorial action (fmap):
  fmap_Mirror : (UV → Value) → (UV → Value)
  fmap_Mirror(f) = f ∘ Mirror

Lift makes this explicit as a combinator card.
```

**Lift vs Composition-Level Functors**:

| Composition-Level Functor | Lift Combinator |
|---------------------------|-----------------|
| Wraps entire composition | Wraps single card |
| `functors: [mirror]` | `lift: { functor: mirror, inner: card }` |
| All columns affected | Only target card affected |
| Global transformation | Local transformation |
| Simpler to use | More precise control |

**Visual Comparison**:

```
Composition-Level Mirror:           Lift(Mirror, Voronoi):

╔═══════════════════════════╗       ┌───────────────────────────┐
║ 🪞 Mirror                  ║       │ No composition functor    │
║                            ║       │                           │
║  Swirl → Voronoi → Palette ║       │ Swirl → ⇑Mirror(Voronoi) │
║  (all mirrored)            ║       │         → Palette         │
╚═══════════════════════════╝       │                           │
                                    │ Only Voronoi is mirrored  │
                                    └───────────────────────────┘

Result: Everything symmetric        Result: Asymmetric swirl,
                                           symmetric voronoi
```

**When to Use Lift**:

| Scenario | Use Lift? | Why |
|----------|-----------|-----|
| Mirror only the noise, not color | ✅ Yes | Selective application |
| Tile the entire composition | ❌ No | Use composition functor |
| Apply feedback to one generator | ✅ Yes | Isolate temporal effect |
| Different tiles for different SDFs | ✅ Yes | Per-card functor params |
| Same effect everywhere | ❌ No | Simpler with composition functor |

**Nested Lift Example**:

```typescript
// Lift can contain other combinators
structure: {
  cards: [{
    cardId: 'lift',
    slots: {
      functor: { functorId: 'tile', params: { countX: 3, countY: 3 } },
      inner: {
        cardId: 'product',  // Product inside Lift!
        slots: {
          left: { cardId: 'circle-sdf', ... },
          right: { cardId: 'noise', ... },
        },
        params: { merge: 'multiply' },
      },
    },
  }],
}
// Result: Tiled(Circle ⊗ Noise) - both circle and noise are tiled together
```

---

### 13.9 Saved Card: "Lava Flow"

```typescript
// After creating the composition above, save as card:
saveAsCard('Lava Flow', [
  { path: 'functors[0].params.persistence', name: 'trails', label: 'Trail Length' },
  { path: 'domain.cards[0].params.amount', name: 'warp', label: 'Heat Distortion' },
  { path: 'structure.cards[0].params.iterations', name: 'detail', label: 'Fractal Detail' },
]);

// Now "Lava Flow" appears in deck with 3 exposed params
// Can be used in new compositions as a single card
```

---

## 14. Future Extensions

### 14.1 Audio Reactivity

```typescript
interface AudioFunctor extends FunctorDefinition {
  id: 'audio-functor';

  // Provides audio analysis uniforms
  provides: {
    bass: 'float',      // Low frequency energy
    mid: 'float',       // Mid frequency energy
    high: 'float',      // High frequency energy
    beat: 'float',      // Beat detection (0 or 1)
    spectrum: 'array',  // Full spectrum
  };

  // Cards can reference these in expressions
  // e.g., scale: '{audio.bass} * 2.0 + 1.0'
}
```

### 14.2 3D Mode (SDF Raymarching)

```typescript
// New object type: SDF3D
// New cards: sphere3D, box3D, torus3D, union3D, subtract3D, etc.
// Automatic raymarcher generation

interface SDF3DCard extends Card {
  signature: { input: 'pos3d', output: 'distance' };
  // pos3d = vec3 (ray position in 3D space)
  // distance = float (signed distance to surface)
}
```

### 14.3 Custom Card Editor

```typescript
// UI for creating new primitive cards
interface CustomCardEditor {
  name: string;
  wgslCode: string;        // User-written WGSL snippet
  signature: MorphismType;  // User-specified types
  params: CardParam[];      // Defined via UI

  // Validation
  validate(): ValidationResult;

  // Test in sandbox
  preview(): void;
}
```

### 14.4 Animation Timeline

```typescript
// Keyframe animation for parameters
interface Timeline {
  duration: number;  // Total duration in seconds
  loop: boolean;

  tracks: TimelineTrack[];
}

interface TimelineTrack {
  target: string;  // Parameter path
  keyframes: Keyframe[];
  easing: EasingFunction;
}

interface Keyframe {
  time: number;    // Seconds
  value: ParamValue;
}
```

### 14.5 Texture Inputs

```typescript
// Cards that sample textures
interface TextureSamplerCard extends Card {
  signature: { input: ['uv', 'texture'], output: 'color' };
}

// UI for uploading/selecting textures
// Textures become available as inputs to sampler cards
```

---

## Appendix A: Lygia Function Inventory

<details>
<summary>Full list of wrapped lygia functions</summary>

### generative/ (15 functions)
- `cnoise(vec2) → float` - Classic Perlin noise
- `snoise(vec2) → float` - Simplex noise
- `snoise(vec3) → float` - 3D simplex noise
- `voronoi(vec2, float) → vec3` - Voronoi (dist, cell, edge)
- `fbm(vec2, int) → float` - Fractal Brownian motion
- `worley(vec2, float) → float` - Worley/cellular noise
- `curl(vec2) → vec2` - Curl noise
- `random(vec2) → float` - Pseudo-random
- `random(float) → float` - 1D random
- ...

### sdf/ (25 functions)
- `circleSDF(vec2, float) → float`
- `rectSDF(vec2, vec2) → float`
- `roundRectSDF(vec2, vec2, float) → float`
- `starSDF(vec2, int, float, float) → float`
- `polySDF(vec2, int) → float`
- `triSDF(vec2) → float`
- `heartSDF(vec2) → float`
- `lineSDF(vec2, vec2, vec2) → float`
- `crossSDF(vec2, float) → float`
- `vesicaSDF(vec2, float) → float`
- ...

### color/palette/ (12 functions)
- `spectral(float) → vec3`
- `heatmap(float) → vec3`
- `viridis(float) → vec3`
- `magma(float) → vec3`
- `inferno(float) → vec3`
- `plasma(float) → vec3`
- `turbo(float) → vec3`
- `cool(float) → vec3`
- `warm(float) → vec3`
- ...

### color/ (20 functions)
- `brightness(vec3, float) → vec3`
- `contrast(vec3, float) → vec3`
- `saturation(vec3, float) → vec3`
- `hueShift(vec3, float) → vec3`
- `luma(vec3) → float`
- `gamma(vec3, float) → vec3`
- `exposure(vec3, float) → vec3`
- `blend*(vec3, vec3) → vec3` (multiple blend modes)
- ...

### space/ (10 functions)
- `tile(vec2, float) → vec2`
- `tile(vec2, vec2) → vec2`
- `rotate(vec2, float) → vec2`
- `scale(vec2, float) → vec2`
- `scale(vec2, vec2) → vec2`
- `mirror(vec2) → vec2`
- `ratio(vec2, vec2) → vec2`
- ...

### filter/ (8 functions)
- `gaussianBlur(texture, sampler, vec2, float) → vec3`
- `boxBlur(texture, sampler, vec2, float) → vec3`
- `sharpen(texture, sampler, vec2) → vec3`
- `edge(texture, sampler, vec2) → vec3`
- `median(texture, sampler, vec2) → vec3`
- ...

</details>

---

## Appendix B: Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+Z` | Undo |
| `Ctrl+Shift+Z` | Redo |
| `Ctrl+S` | Save to localStorage |
| `Ctrl+E` | Export PNG |
| `Ctrl+C` | Copy selected card |
| `Ctrl+V` | Paste card |
| `Delete` | Remove selected card |
| `Space` | Toggle selected card |
| `Tab` | Next card |
| `Shift+Tab` | Previous card |
| `1` / `2` / `3` | Focus column |
| `Ctrl+1` | Add to domain |
| `Ctrl+2` | Add to structure |
| `Ctrl+3` | Add to codomain |
| `/` | Focus search |
| `?` | Show help |

---

## Document History

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2025-01-05 | 1.0 | Claude | Initial comprehensive plan |
