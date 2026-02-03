# PNGine Shader Composer Plan

> A card-based visual shader composer inspired by Gwent, powered by the lygia shader library

---

## Executive Summary

This document describes **PNGine Composer**, a web application that lets users create GPU shaders by stacking cards in a three-column layout—no code required. Users drag "Source" cards (patterns, shapes, noise) to the left column and "Style" cards (colors, effects) to the right column. The middle column shows a live preview of the combined result. When satisfied, users export a self-contained `.png` file that runs anywhere.

**The vision**: Democratize shader art. Make GPU programming as accessible as a card game.

**Key insight**: The lygia shader library contains 250+ WGSL functions covering noise, shapes, colors, and effects. By decomposing these into composable cards with clear inputs/outputs, we can create a visual shader language that generates real, optimized code.

---

## Background

### What is PNGine?

PNGine is a WebGPU bytecode engine that compiles a domain-specific language (DSL) into compact bytecode embedded in PNG files. A shader that would normally require hundreds of lines of boilerplate fits in ~500 bytes of bytecode, packaged in a PNG that runs in any browser.

**Current workflow** (developer-focused):
```
Write .pngine DSL → Compile → Get PNG → Share
```

**Proposed workflow** (anyone):
```
Stack cards → See preview → Download PNG → Share
```

### What is lygia?

[lygia](https://lygia.xyz) is the largest cross-platform shader library, containing:
- **254 WGSL functions** (WebGPU-ready)
- **656 GLSL functions** (reference implementations)
- Categories: noise, SDF shapes, color palettes, filters, animation, lighting
- MIT-style license (Prosperity + Patron)
- Battle-tested in production (Unity, Three.js, TouchDesigner)

lygia's modular design (one function per file) makes it ideal for decomposition into composable cards.

### Why Cards?

Card-based interfaces have proven successful for complex composition tasks:
- **Gwent/Hearthstone**: Strategic card placement creates emergent gameplay
- **Node-based editors**: Powerful but intimidating (Blender, Unreal)
- **Block-based coding**: Scratch proved visual programming works

Cards offer:
1. **Discoverability** - Browse available options visually
2. **Composability** - Stack order creates different results
3. **Adjustability** - Parameters exposed as sliders
4. **Shareability** - A "deck" is a recipe that can be shared

---

## The Three-Column Model

Inspired by Gwent's battlefield layout:

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│   SOURCES (Left)         PREVIEW (Middle)        STYLES (Right)    │
│   ───────────────        ────────────────        ──────────────    │
│                                                                     │
│   What patterns          Live result of          How patterns      │
│   exist in the           left + right            are colored       │
│   shader                 combined                and modified      │
│                                                                     │
│   ┌─────────────┐       ┌─────────────────┐     ┌─────────────┐   │
│   │ Perlin      │       │                 │     │ Rainbow     │   │
│   │ Noise    ●──┼───────┼──▶              │     │ Palette  ●──┼─┐ │
│   │ scale: 4.0  │       │                 │     │ cycles: 1   │ │ │
│   └─────────────┘       │   ┌─────────┐   │     └─────────────┘ │ │
│   ┌─────────────┐       │   │         │   │     ┌─────────────┐ │ │
│   │ Circle      │       │   │  LIVE   │◀──┼─────┤ Glow        │ │ │
│   │ SDF      ●──┼───────┼──▶│ SHADER  │   │     │          ●──┼─┤ │
│   │ radius: 0.3 │       │   │         │   │     │ intensity:  │ │ │
│   └─────────────┘       │   └─────────┘   │     │ 0.5         │ │ │
│   ┌─────────────┐       │                 │     └─────────────┘ │ │
│   │ Warp        │       │                 │     ┌─────────────┐ │ │
│   │ Distort  ●──┼───────┼──▶              │     │ Vignette ●──┼─┘ │
│   │ amount: 0.2 │       │                 │     │ strength:   │   │
│   └─────────────┘       │                 │     │ 0.4         │   │
│                         │                 │     └─────────────┘   │
│   Stack: 3 cards        └─────────────────┘     Stack: 3 cards    │
│   Blend: Multiply        Size: 1.8 KB           Order: Top→Down   │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│   [View Code]    [Copy DSL]    [Download PNG]    [Share Link]      │
├─────────────────────────────────────────────────────────────────────┤
│                           CARD DECK                                 │
│   ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐        │
│   │Noise│ │Circle│ │Voron│ │Rainb│ │Glow │ │Blur │ │Pixel│  ...   │
│   └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘        │
│                         ← drag to columns →                        │
└─────────────────────────────────────────────────────────────────────┘
```

### Data Flow

```
UV Coordinates (screen position)
        │
        ▼
┌───────────────────┐
│   LEFT COLUMN     │
│   (Sources)       │
│                   │
│   UV → Transform  │  ← Tile, Mirror, Rotate, Scale
│        │          │
│        ▼          │
│   UV → Generator  │  ← Noise, SDF, Gradient
│        │          │
│        ▼          │
│   UV → Generator  │  ← Stack multiple, blend together
│        │          │
│        ▼          │
│   Output: float   │  ← Value 0.0 to 1.0
└───────────────────┘
        │
        ▼
┌───────────────────┐
│   RIGHT COLUMN    │
│   (Styles)        │
│                   │
│   float → Color   │  ← Palette mapping (Rainbow, Heatmap)
│        │          │
│        ▼          │
│   color → Effect  │  ← Glow, Blur, Pixelate
│        │          │
│        ▼          │
│   color → Adjust  │  ← Contrast, Saturation, Vignette
│        │          │
│        ▼          │
│   Output: vec3    │  ← RGB color
└───────────────────┘
        │
        ▼
    Final Pixel
```

---

## Card Taxonomy

### Category 1: Source Cards (LEFT Column)

Cards that generate patterns from UV coordinates. Output is a `float` value (0.0 to 1.0).

#### Noise Cards

| Card | lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Perlin Noise** | `generative/cnoise` | scale, speed, octaves | Classic smooth noise |
| **Simplex Noise** | `generative/snoise` | scale, speed | Faster, fewer artifacts |
| **Voronoi** | `generative/voronoi` | scale, jitter | Cell-based pattern |
| **FBM** | `generative/fbm` | scale, octaves, gain | Layered noise (clouds) |
| **Curl Noise** | `generative/curl` | scale, speed | Flowing, organic |
| **White Noise** | `generative/random` | seed | Pure randomness |
| **Worley** | `generative/worley` | scale, jitter | Distance to nearest point |

#### Shape Cards (SDF)

| Card | lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Circle** | `sdf/circleSDF` | radius, softness, x, y | Round shape |
| **Rectangle** | `sdf/rectSDF` | width, height, softness | Box shape |
| **Rounded Rect** | `sdf/roundRectSDF` | width, height, radius | Rounded corners |
| **Triangle** | `sdf/triSDF` | size, rotation | Three-sided |
| **Star** | `sdf/starSDF` | points, inner, outer | Star shape |
| **Heart** | `sdf/heartSDF` | size | Heart shape |
| **Polygon** | `sdf/polySDF` | sides, size | N-sided polygon |
| **Line** | `sdf/lineSDF` | x1, y1, x2, y2, width | Line segment |
| **Ring** | `sdf/annularSDF` | inner, outer | Donut shape |

#### Gradient Cards

| Card | lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Horizontal** | (custom) | angle | Left to right |
| **Vertical** | (custom) | angle | Top to bottom |
| **Radial** | (custom) | centerX, centerY | Center outward |
| **Angular** | (custom) | centerX, centerY | Sweep around |
| **Diamond** | (custom) | centerX, centerY | Diamond pattern |

#### Pattern Cards

| Card | lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Checker** | (custom) | scale | Checkerboard |
| **Stripes** | (custom) | count, angle, duty | Parallel lines |
| **Dots** | (custom) | scale, size | Polka dots |
| **Grid** | (custom) | scaleX, scaleY, thickness | Grid lines |
| **Waves** | `generative/gerstnerWave` | amplitude, frequency, speed | Water waves |

#### Transform Cards (Pre-process UV)

| Card | lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Tile** | `space/tile` | countX, countY | Repeat pattern |
| **Mirror** | `space/mirror` | axisX, axisY | Reflect pattern |
| **Rotate** | `space/rotate` | angle, centerX, centerY | Spin pattern |
| **Scale** | `space/scale` | scaleX, scaleY | Zoom in/out |
| **Translate** | (custom) | offsetX, offsetY | Move pattern |
| **Warp** | (custom) | noiseScale, amount | Distort with noise |
| **Twist** | (custom) | amount, centerX, centerY | Spiral distortion |
| **Fisheye** | (custom) | amount | Lens distortion |
| **Kaleidoscope** | (custom) | segments | Radial symmetry |

### Category 2: Style Cards (RIGHT Column)

Cards that transform values into colors or modify colors.

#### Palette Cards (float → color)

| Card | lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Rainbow** | `color/palette/spectral` | offset, cycles | Full spectrum |
| **Heatmap** | `color/palette/heatmap` | offset | Cold to hot |
| **Viridis** | `color/palette/viridis` | offset | Scientific (blue-green-yellow) |
| **Magma** | `color/palette/magma` | offset | Dark to bright (volcanic) |
| **Inferno** | `color/palette/inferno` | offset | Black-red-yellow-white |
| **Plasma** | `color/palette/plasma` | offset | Purple-pink-orange-yellow |
| **Turbo** | `color/palette/turbo` | offset | Improved rainbow |
| **Grayscale** | (custom) | invert | Black to white |
| **Duotone** | (custom) | color1, color2 | Two-color gradient |
| **Custom** | (custom) | color1, color2, color3 | Three-stop gradient |

#### Effect Cards (color → color)

| Card | lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Glow** | (custom) | intensity, radius | Bloom/glow effect |
| **Blur** | `filter/gaussianBlur` | radius | Soft blur |
| **Sharpen** | `filter/sharpen` | amount | Edge enhancement |
| **Pixelate** | `sample/pixelate` | size | Retro pixels |
| **Posterize** | `color/posterize` | levels | Reduce colors |
| **Dither** | (custom) | pattern, scale | Dithering effect |
| **Edge Glow** | (custom) | color, width | Outline glow |
| **Drop Shadow** | (custom) | offsetX, offsetY, blur, color | Shadow behind |

#### Adjustment Cards (color → color)

| Card | lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Brightness** | `color/brightness` | amount | Lighten/darken |
| **Contrast** | `color/contrast` | amount | Increase/decrease contrast |
| **Saturation** | `color/saturation` | amount | Color intensity |
| **Hue Shift** | `color/hueShift` | degrees | Rotate hue |
| **Invert** | (custom) | amount | Negative |
| **Gamma** | (custom) | gamma | Gamma correction |
| **Exposure** | (custom) | stops | Photographic exposure |
| **Vignette** | (custom) | strength, softness | Dark edges |
| **Color Tint** | (custom) | color, amount | Overlay color |

#### Blend Cards (combine multiple sources)

| Card | Purpose | Parameters |
|------|---------|------------|
| **Add** | Lighten, combine | opacity |
| **Multiply** | Darken, mask | opacity |
| **Screen** | Lighten, dodge | opacity |
| **Overlay** | Contrast boost | opacity |
| **Soft Light** | Gentle blend | opacity |
| **Difference** | Psychedelic | opacity |
| **Max** | Brightest wins | — |
| **Min** | Darkest wins | — |

#### Animation Cards (time-based modulation)

| Card | lygia Function | Parameters | Description |
|------|----------------|------------|-------------|
| **Pulse** | (custom) | speed, min, max | Breathing effect |
| **Wave** | `animation/easing/sineInOut` | speed, amplitude | Smooth oscillation |
| **Bounce** | `animation/easing/bounceOut` | speed | Bouncy motion |
| **Noise Time** | (custom) | speed, amount | Jittery variation |
| **Step** | (custom) | speed, steps | Discrete jumps |

---

## Card Data Structure

### TypeScript Interface

```typescript
interface Card {
  // Identity
  id: string;                    // Unique identifier: "perlin-noise"
  name: string;                  // Display name: "Perlin Noise"
  description: string;           // Tooltip: "Classic smooth noise pattern"

  // Classification
  category: 'source' | 'style' | 'transform' | 'blend' | 'animation';
  column: 'left' | 'right' | 'both';
  tags: string[];                // For filtering: ["noise", "organic", "animated"]

  // Dependencies
  lygiaImports: string[];        // ["generative/cnoise", "math/mod289"]

  // Type System
  inputType: 'none' | 'uv' | 'float' | 'color';
  outputType: 'float' | 'color' | 'uv';

  // Parameters (become uniforms + UI controls)
  params: CardParam[];

  // Code Generation
  wgsl: string;                  // Template with {placeholders}

  // Visual
  icon: string;                  // Emoji or icon name
  previewColor: string;          // Card border color
  thumbnail?: string;            // Base64 preview image
}

interface CardParam {
  name: string;                  // "scale"
  label: string;                 // "Scale"
  type: 'float' | 'int' | 'vec2' | 'vec3' | 'color' | 'bool' | 'select';
  default: number | number[] | string | boolean;

  // For numeric types
  range?: [number, number];      // [0.1, 20]
  step?: number;                 // 0.1

  // For select type
  options?: { value: string; label: string }[];

  // UI hints
  group?: string;                // Group related params
  advanced?: boolean;            // Hide in simple mode
}
```

### Example Card Definitions

```typescript
const cards: Card[] = [
  // ─────────────────────────────────────────────────────────────
  // SOURCE CARDS
  // ─────────────────────────────────────────────────────────────

  {
    id: 'perlin-noise',
    name: 'Perlin Noise',
    description: 'Classic smooth, organic noise pattern. Great for clouds, terrain, and natural textures.',
    category: 'source',
    column: 'left',
    tags: ['noise', 'organic', 'animated', 'classic'],
    lygiaImports: ['generative/cnoise'],
    inputType: 'uv',
    outputType: 'float',
    params: [
      { name: 'scale', label: 'Scale', type: 'float', default: 4.0, range: [0.5, 20], step: 0.5 },
      { name: 'speed', label: 'Speed', type: 'float', default: 0.5, range: [0, 3], step: 0.1 },
      { name: 'offsetX', label: 'Offset X', type: 'float', default: 0, range: [-10, 10], advanced: true },
      { name: 'offsetY', label: 'Offset Y', type: 'float', default: 0, range: [-10, 10], advanced: true },
    ],
    wgsl: `cnoise(uv * {scale} + vec2f({offsetX} + time * {speed}, {offsetY})) * 0.5 + 0.5`,
    icon: '🌊',
    previewColor: '#4a9eff',
  },

  {
    id: 'circle-sdf',
    name: 'Circle',
    description: 'A circular shape with adjustable radius and edge softness.',
    category: 'source',
    column: 'left',
    tags: ['shape', 'sdf', 'geometric'],
    lygiaImports: ['sdf/circleSDF'],
    inputType: 'uv',
    outputType: 'float',
    params: [
      { name: 'radius', label: 'Radius', type: 'float', default: 0.3, range: [0.01, 0.8], step: 0.01 },
      { name: 'softness', label: 'Edge Softness', type: 'float', default: 0.01, range: [0.001, 0.2], step: 0.001 },
      { name: 'centerX', label: 'Center X', type: 'float', default: 0.5, range: [0, 1], step: 0.01 },
      { name: 'centerY', label: 'Center Y', type: 'float', default: 0.5, range: [0, 1], step: 0.01 },
    ],
    wgsl: `1.0 - smoothstep(0.0, {softness}, circleSDF(uv - vec2f({centerX}, {centerY}), {radius}))`,
    icon: '⭕',
    previewColor: '#ff6b6b',
  },

  {
    id: 'voronoi',
    name: 'Voronoi Cells',
    description: 'Organic cell-based pattern. Great for cracked surfaces, biological textures, and abstract art.',
    category: 'source',
    column: 'left',
    tags: ['noise', 'cellular', 'organic'],
    lygiaImports: ['generative/voronoi'],
    inputType: 'uv',
    outputType: 'float',
    params: [
      { name: 'scale', label: 'Scale', type: 'float', default: 8.0, range: [2, 30], step: 1 },
      { name: 'jitter', label: 'Jitter', type: 'float', default: 1.0, range: [0, 1], step: 0.1 },
      { name: 'speed', label: 'Speed', type: 'float', default: 0.2, range: [0, 2], step: 0.1 },
    ],
    wgsl: `voronoi(uv * {scale} + time * {speed}, {jitter}).x`,
    icon: '🔷',
    previewColor: '#9b59b6',
  },

  // ─────────────────────────────────────────────────────────────
  // TRANSFORM CARDS
  // ─────────────────────────────────────────────────────────────

  {
    id: 'tile',
    name: 'Tile',
    description: 'Repeat the pattern in a grid.',
    category: 'transform',
    column: 'left',
    tags: ['transform', 'repeat', 'pattern'],
    lygiaImports: ['space/tile'],
    inputType: 'uv',
    outputType: 'uv',
    params: [
      { name: 'countX', label: 'Columns', type: 'int', default: 3, range: [1, 20], step: 1 },
      { name: 'countY', label: 'Rows', type: 'int', default: 3, range: [1, 20], step: 1 },
    ],
    wgsl: `fract(uv * vec2f(f32({countX}), f32({countY})))`,
    icon: '🔲',
    previewColor: '#3498db',
  },

  {
    id: 'rotate',
    name: 'Rotate',
    description: 'Spin the pattern around a center point.',
    category: 'transform',
    column: 'left',
    tags: ['transform', 'rotation'],
    lygiaImports: ['space/rotate'],
    inputType: 'uv',
    outputType: 'uv',
    params: [
      { name: 'angle', label: 'Angle', type: 'float', default: 0, range: [0, 360], step: 1 },
      { name: 'speed', label: 'Spin Speed', type: 'float', default: 0, range: [-2, 2], step: 0.1 },
      { name: 'centerX', label: 'Center X', type: 'float', default: 0.5, range: [0, 1], advanced: true },
      { name: 'centerY', label: 'Center Y', type: 'float', default: 0.5, range: [0, 1], advanced: true },
    ],
    wgsl: `rotate(uv - vec2f({centerX}, {centerY}), radians({angle}) + time * {speed}) + vec2f({centerX}, {centerY})`,
    icon: '🔄',
    previewColor: '#e74c3c',
  },

  // ─────────────────────────────────────────────────────────────
  // STYLE CARDS - PALETTES
  // ─────────────────────────────────────────────────────────────

  {
    id: 'rainbow-palette',
    name: 'Rainbow',
    description: 'Map values to a full spectrum of colors.',
    category: 'style',
    column: 'right',
    tags: ['palette', 'colorful', 'spectrum'],
    lygiaImports: ['color/palette/spectral'],
    inputType: 'float',
    outputType: 'color',
    params: [
      { name: 'offset', label: 'Offset', type: 'float', default: 0, range: [0, 1], step: 0.01 },
      { name: 'cycles', label: 'Cycles', type: 'float', default: 1, range: [0.5, 5], step: 0.5 },
    ],
    wgsl: `spectral(fract({input} * {cycles} + {offset}))`,
    icon: '🌈',
    previewColor: '#ff9f43',
  },

  {
    id: 'heatmap-palette',
    name: 'Heatmap',
    description: 'Cold blue to hot red color mapping.',
    category: 'style',
    column: 'right',
    tags: ['palette', 'scientific', 'temperature'],
    lygiaImports: ['color/palette/heatmap'],
    inputType: 'float',
    outputType: 'color',
    params: [
      { name: 'offset', label: 'Offset', type: 'float', default: 0, range: [0, 1], step: 0.01 },
    ],
    wgsl: `heatmap(clamp({input} + {offset}, 0.0, 1.0))`,
    icon: '🔥',
    previewColor: '#e74c3c',
  },

  {
    id: 'duotone-palette',
    name: 'Duotone',
    description: 'Map values between two custom colors.',
    category: 'style',
    column: 'right',
    tags: ['palette', 'custom', 'gradient'],
    lygiaImports: [],
    inputType: 'float',
    outputType: 'color',
    params: [
      { name: 'color1', label: 'Color 1', type: 'color', default: [0.1, 0.1, 0.3] },
      { name: 'color2', label: 'Color 2', type: 'color', default: [1.0, 0.8, 0.2] },
    ],
    wgsl: `mix(vec3f({color1}), vec3f({color2}), {input})`,
    icon: '🎨',
    previewColor: '#8e44ad',
  },

  // ─────────────────────────────────────────────────────────────
  // STYLE CARDS - EFFECTS
  // ─────────────────────────────────────────────────────────────

  {
    id: 'glow',
    name: 'Glow',
    description: 'Add a bloom/glow effect around bright areas.',
    category: 'style',
    column: 'right',
    tags: ['effect', 'bloom', 'light'],
    lygiaImports: [],
    inputType: 'color',
    outputType: 'color',
    params: [
      { name: 'intensity', label: 'Intensity', type: 'float', default: 0.5, range: [0, 2], step: 0.1 },
      { name: 'threshold', label: 'Threshold', type: 'float', default: 0.5, range: [0, 1], step: 0.05 },
    ],
    wgsl: `{input} + {input} * max(0.0, (length({input}) - {threshold})) * {intensity}`,
    icon: '✨',
    previewColor: '#f1c40f',
  },

  {
    id: 'vignette',
    name: 'Vignette',
    description: 'Darken the edges of the image for a cinematic look.',
    category: 'style',
    column: 'right',
    tags: ['effect', 'cinematic', 'edges'],
    lygiaImports: [],
    inputType: 'color',
    outputType: 'color',
    params: [
      { name: 'strength', label: 'Strength', type: 'float', default: 0.4, range: [0, 1], step: 0.05 },
      { name: 'softness', label: 'Softness', type: 'float', default: 0.5, range: [0.1, 1], step: 0.05 },
    ],
    wgsl: `{input} * (1.0 - {strength} * smoothstep({softness}, 1.0, length(uv - 0.5) * 2.0))`,
    icon: '🎬',
    previewColor: '#2c3e50',
  },

  {
    id: 'contrast',
    name: 'Contrast',
    description: 'Increase or decrease the difference between light and dark.',
    category: 'style',
    column: 'right',
    tags: ['adjustment', 'contrast'],
    lygiaImports: ['color/contrast'],
    inputType: 'color',
    outputType: 'color',
    params: [
      { name: 'amount', label: 'Amount', type: 'float', default: 1.0, range: [0, 3], step: 0.1 },
    ],
    wgsl: `contrast({input}, {amount})`,
    icon: '◐',
    previewColor: '#34495e',
  },
];
```

---

## Code Generation

### Stack State

```typescript
interface ComposerState {
  // The two stacks
  leftStack: StackedCard[];
  rightStack: StackedCard[];

  // Global settings
  blendMode: 'add' | 'multiply' | 'max' | 'min' | 'average';
  resolution: { width: number; height: number };

  // Metadata
  name: string;
  author: string;
  description: string;
}

interface StackedCard {
  card: Card;
  params: Record<string, number | number[] | string | boolean>;
  enabled: boolean;
  id: string; // Unique instance ID
}
```

### WGSL Generation Algorithm

```typescript
function generateWGSL(state: ComposerState): string {
  const { leftStack, rightStack, blendMode } = state;

  // 1. Collect all lygia imports
  const imports = new Set<string>();
  [...leftStack, ...rightStack].forEach(sc => {
    if (sc.enabled) {
      sc.card.lygiaImports.forEach(i => imports.add(i));
    }
  });

  // 2. Build uniform struct
  const uniforms = buildUniformStruct(state);

  // 3. Generate lygia function inlines
  const lygiaCode = inlineLygiaFunctions([...imports]);

  // 4. Build source chain (left stack)
  const sourceCode = generateSourceChain(leftStack, blendMode);

  // 5. Build style chain (right stack)
  const styleCode = generateStyleChain(rightStack);

  // 6. Assemble final shader
  return `
// ═══════════════════════════════════════════════════════════════
// Generated by PNGine Composer
// ${state.name} by ${state.author}
// ═══════════════════════════════════════════════════════════════

${uniforms}

${lygiaCode}

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let resolution = vec2f(u.width, u.height);
  var uv = pos.xy / resolution;
  uv.y = 1.0 - uv.y; // Flip Y for standard orientation
  let time = u.time;

  // ─── SOURCES (Left Stack) ───────────────────────────────────
  ${sourceCode}

  // ─── STYLES (Right Stack) ───────────────────────────────────
  ${styleCode}

  return vec4f(color, 1.0);
}
`;
}

function generateSourceChain(stack: StackedCard[], blendMode: string): string {
  const enabled = stack.filter(s => s.enabled);
  if (enabled.length === 0) {
    return 'var value: f32 = 0.5; // No sources';
  }

  let code = '';
  let valueIndex = 0;
  let currentUV = 'uv';

  for (const sc of enabled) {
    const card = sc.card;

    // Handle transforms (modify UV)
    if (card.outputType === 'uv') {
      const transformCode = substituteParams(card.wgsl, sc.params, currentUV);
      code += `  let uv${++valueIndex} = ${transformCode};\n`;
      currentUV = `uv${valueIndex}`;
      continue;
    }

    // Handle sources (generate values)
    if (card.outputType === 'float') {
      const sourceCode = substituteParams(card.wgsl, sc.params, currentUV);
      code += `  let v${++valueIndex} = ${sourceCode};\n`;
    }
  }

  // Combine all values with blend mode
  const values = Array.from({ length: valueIndex }, (_, i) => `v${i + 1}`)
    .filter(v => !v.startsWith('uv'));

  if (values.length === 0) {
    code += '  var value: f32 = 0.5;\n';
  } else if (values.length === 1) {
    code += `  var value: f32 = ${values[0]};\n`;
  } else {
    const blendExpr = blendValues(values, blendMode);
    code += `  var value: f32 = ${blendExpr};\n`;
  }

  return code;
}

function generateStyleChain(stack: StackedCard[]): string {
  const enabled = stack.filter(s => s.enabled);

  let code = '  var color = vec3f(value); // Default grayscale\n';
  let currentInput = 'value';

  for (const sc of enabled) {
    const card = sc.card;

    // Palette: float → color
    if (card.inputType === 'float' && card.outputType === 'color') {
      const paletteCode = substituteParams(card.wgsl, sc.params, currentInput);
      code += `  color = ${paletteCode};\n`;
      currentInput = 'color';
      continue;
    }

    // Effect/Adjustment: color → color
    if (card.inputType === 'color' && card.outputType === 'color') {
      const effectCode = substituteParams(card.wgsl, sc.params, 'color');
      code += `  color = ${effectCode};\n`;
    }
  }

  return code;
}

function substituteParams(
  template: string,
  params: Record<string, any>,
  input: string
): string {
  let result = template.replace('{input}', input);
  result = result.replace(/\{uv\}/g, input.startsWith('uv') ? input : 'uv');

  for (const [key, value] of Object.entries(params)) {
    const placeholder = `{${key}}`;
    if (Array.isArray(value)) {
      result = result.replace(placeholder, value.join(', '));
    } else {
      result = result.replace(placeholder, String(value));
    }
  }

  return result;
}

function blendValues(values: string[], mode: string): string {
  switch (mode) {
    case 'add':
      return `clamp(${values.join(' + ')}, 0.0, 1.0)`;
    case 'multiply':
      return values.join(' * ');
    case 'max':
      return values.reduce((a, b) => `max(${a}, ${b})`);
    case 'min':
      return values.reduce((a, b) => `min(${a}, ${b})`);
    case 'average':
      return `(${values.join(' + ')}) / ${values.length}.0`;
    default:
      return values[0];
  }
}
```

### PNGine DSL Generation

```typescript
function generatePNGineDSL(state: ComposerState, wgsl: string): string {
  const defines = extractDefines(state);

  return `// ═══════════════════════════════════════════════════════════════
// ${state.name}
// Generated by PNGine Composer
// Author: ${state.author}
// ═══════════════════════════════════════════════════════════════

${defines}

#buffer uniforms {
  size=16
  usage=[UNIFORM COPY_DST]
}

#queue writeUniforms {
  writeBuffer={
    buffer=uniforms
    bufferOffset=0
    data=pngineInputs
  }
}

#shaderModule shader {
  code="${escapeWGSL(wgsl)}"
}

#renderPipeline pipeline {
  layout=auto
  vertex={ module=shader entryPoint="vs" }
  fragment={
    module=shader
    entryPoint="fs"
    targets=[{ format=preferredCanvasFormat }]
  }
}

#renderPass render {
  colorAttachments=[{
    view=contextCurrentTexture
    clearValue=[0 0 0 1]
    loadOp=clear
    storeOp=store
  }]
  pipeline=pipeline
  draw=3
}

#frame main {
  perform=[writeUniforms render]
}
`;
}
```

---

## User Interface Design

### Layout Structure

```
┌────────────────────────────────────────────────────────────────────────┐
│  HEADER                                                                │
│  ┌────────────────────────────────────────────────────────────────┐   │
│  │  PNGine Composer          [New] [Load] [Save]     [? Help]     │   │
│  └────────────────────────────────────────────────────────────────┘   │
├────────────────────────────────────────────────────────────────────────┤
│  WORKSPACE                                                             │
│  ┌──────────────┬────────────────────────┬──────────────┐             │
│  │              │                        │              │             │
│  │   SOURCES    │       PREVIEW          │    STYLES    │             │
│  │   (Left)     │       (Center)         │    (Right)   │             │
│  │              │                        │              │             │
│  │  ┌────────┐  │   ┌────────────────┐   │  ┌────────┐  │             │
│  │  │ Card 1 │  │   │                │   │  │ Card 1 │  │             │
│  │  └────────┘  │   │                │   │  └────────┘  │             │
│  │  ┌────────┐  │   │     LIVE       │   │  ┌────────┐  │             │
│  │  │ Card 2 │  │   │    SHADER      │   │  │ Card 2 │  │             │
│  │  └────────┘  │   │                │   │  └────────┘  │             │
│  │  ┌────────┐  │   │                │   │  ┌────────┐  │             │
│  │  │ Card 3 │  │   └────────────────┘   │  │ Card 3 │  │             │
│  │  └────────┘  │                        │  └────────┘  │             │
│  │              │   Blend: [Multiply ▾]  │              │             │
│  │  + Add Card  │   Size: 1.8 KB         │  + Add Card  │             │
│  │              │                        │              │             │
│  └──────────────┴────────────────────────┴──────────────┘             │
├────────────────────────────────────────────────────────────────────────┤
│  ACTIONS                                                               │
│  ┌────────────────────────────────────────────────────────────────┐   │
│  │  [View Code]  [Copy DSL]  [Download PNG]  [Share Link]          │   │
│  └────────────────────────────────────────────────────────────────┘   │
├────────────────────────────────────────────────────────────────────────┤
│  CARD DECK (Scrollable)                                               │
│  ┌────────────────────────────────────────────────────────────────┐   │
│  │  Filter: [All ▾] [🔍 Search...]                                 │   │
│  │                                                                  │   │
│  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ...  │   │
│  │  │ 🌊  │ │ ⭕  │ │ 🔷  │ │ 🔲  │ │ 🌈  │ │ 🔥  │ │ ✨  │       │   │
│  │  │Noise│ │Circl│ │Voron│ │ Tile│ │Rainb│ │ Heat│ │ Glow│       │   │
│  │  └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘       │   │
│  │                                                                  │   │
│  └────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────┘
```

### Card Component

```
┌─────────────────────────────────┐
│  🌊 Perlin Noise          [×]  │  ← Header (icon, name, remove)
├─────────────────────────────────┤
│                                 │
│  Scale                          │  ← Parameters (when expanded)
│  ━━━━━━━●━━━━━━  4.0           │
│                                 │
│  Speed                          │
│  ━━●━━━━━━━━━━━  0.5           │
│                                 │
│  [Advanced ▾]                   │  ← Toggle advanced params
│                                 │
├─────────────────────────────────┤
│  [↑] [↓] [👁] [⚙]              │  ← Actions (reorder, toggle, settings)
└─────────────────────────────────┘
```

### Interactions

| Action | Trigger | Result |
|--------|---------|--------|
| Add card | Drag from deck to column | Card appears in stack |
| Add card | Click card in deck | Card added to appropriate column |
| Remove card | Click × on card | Card removed from stack |
| Reorder | Drag card within column | Stack order changes |
| Edit params | Click card in stack | Expand parameter sliders |
| Disable card | Click 👁 toggle | Card grayed out, excluded from output |
| Change blend | Select blend mode dropdown | Sources combined differently |

---

## Technical Architecture

### Component Structure

```
src/
├── app/
│   ├── page.tsx                 # Main composer page
│   └── layout.tsx               # App layout
├── components/
│   ├── Workspace/
│   │   ├── Workspace.tsx        # Three-column layout
│   │   ├── SourceColumn.tsx     # Left column
│   │   ├── PreviewColumn.tsx    # Center column
│   │   └── StyleColumn.tsx      # Right column
│   ├── Card/
│   │   ├── Card.tsx             # Card component
│   │   ├── CardDeck.tsx         # Bottom card browser
│   │   ├── CardParams.tsx       # Parameter sliders
│   │   └── CardPreview.tsx      # Mini preview on card
│   ├── Preview/
│   │   ├── ShaderPreview.tsx    # WebGPU canvas
│   │   └── PreviewControls.tsx  # Size, time controls
│   ├── Export/
│   │   ├── CodeModal.tsx        # View generated code
│   │   └── ExportButton.tsx     # Download PNG
│   └── ui/                      # Shared UI components
├── lib/
│   ├── cards/
│   │   ├── definitions.ts       # Card definitions
│   │   ├── registry.ts          # Card registry
│   │   └── categories.ts        # Card categories
│   ├── codegen/
│   │   ├── wgsl.ts              # WGSL generation
│   │   ├── pngine.ts            # PNGine DSL generation
│   │   └── lygia.ts             # Lygia function inlining
│   ├── preview/
│   │   ├── renderer.ts          # WebGPU renderer
│   │   └── compiler.ts          # Shader compilation
│   └── state/
│       ├── store.ts             # Zustand store
│       └── persistence.ts       # LocalStorage + URL
├── data/
│   └── lygia/                   # Inlined lygia WGSL functions
└── styles/
    └── globals.css              # Tailwind + custom styles
```

### State Management (Zustand)

```typescript
import { create } from 'zustand';
import { persist } from 'zustand/middleware';

interface ComposerStore {
  // State
  leftStack: StackedCard[];
  rightStack: StackedCard[];
  blendMode: BlendMode;
  selectedCard: string | null;

  // Actions
  addCard: (card: Card, column: 'left' | 'right') => void;
  removeCard: (id: string) => void;
  moveCard: (id: string, newIndex: number) => void;
  updateParams: (id: string, params: Record<string, any>) => void;
  toggleCard: (id: string) => void;
  setBlendMode: (mode: BlendMode) => void;
  selectCard: (id: string | null) => void;

  // Computed
  getGeneratedWGSL: () => string;
  getGeneratedDSL: () => string;

  // Persistence
  saveToURL: () => string;
  loadFromURL: (encoded: string) => void;
}

export const useComposer = create<ComposerStore>()(
  persist(
    (set, get) => ({
      leftStack: [],
      rightStack: [],
      blendMode: 'multiply',
      selectedCard: null,

      addCard: (card, column) => {
        const instance: StackedCard = {
          card,
          params: Object.fromEntries(
            card.params.map(p => [p.name, p.default])
          ),
          enabled: true,
          id: `${card.id}-${Date.now()}`,
        };

        set(state => ({
          [column === 'left' ? 'leftStack' : 'rightStack']: [
            ...state[column === 'left' ? 'leftStack' : 'rightStack'],
            instance,
          ],
        }));
      },

      // ... other actions
    }),
    { name: 'pngine-composer' }
  )
);
```

### Preview Renderer

```typescript
class ShaderPreviewRenderer {
  private device: GPUDevice;
  private context: GPUCanvasContext;
  private pipeline: GPURenderPipeline | null = null;
  private uniformBuffer: GPUBuffer;
  private startTime: number;

  async updateShader(wgsl: string): Promise<{ success: boolean; error?: string }> {
    try {
      const module = this.device.createShaderModule({ code: wgsl });
      const info = await module.getCompilationInfo();

      const errors = info.messages.filter(m => m.type === 'error');
      if (errors.length > 0) {
        return { success: false, error: errors[0].message };
      }

      this.pipeline = this.device.createRenderPipeline({
        layout: 'auto',
        vertex: { module, entryPoint: 'vs' },
        fragment: {
          module,
          entryPoint: 'fs',
          targets: [{ format: navigator.gpu.getPreferredCanvasFormat() }],
        },
      });

      return { success: true };
    } catch (e) {
      return { success: false, error: String(e) };
    }
  }

  render() {
    if (!this.pipeline) return;

    const time = (performance.now() - this.startTime) / 1000;
    // Update uniforms, render frame...
  }
}
```

---

## Implementation Phases

### Phase 1: Foundation (Week 1-2)

**Goal**: Basic card composition with live preview

- [ ] Project setup (Next.js + Tailwind + Zustand)
- [ ] Card data structure and 10 initial cards
- [ ] Three-column layout
- [ ] Drag-drop from deck to columns
- [ ] Basic WGSL generation (single source + single style)
- [ ] WebGPU preview canvas
- [ ] Live shader compilation and rendering

**Deliverable**: Can drag Noise card to left, Rainbow to right, see result

### Phase 2: Card System (Week 2-3)

**Goal**: Full card interaction and parameter editing

- [ ] Card component with expand/collapse
- [ ] Parameter sliders (float, int, color, select)
- [ ] Card reordering within columns
- [ ] Card enable/disable toggle
- [ ] Remove card functionality
- [ ] 30 cards total (10 source, 10 transform, 10 style)
- [ ] Blend mode selector

**Deliverable**: Can build complex compositions with multiple cards

### Phase 3: Code Generation (Week 3-4)

**Goal**: Complete code generation pipeline

- [ ] Multi-card source blending
- [ ] Transform card UV modification
- [ ] Style chain composition
- [ ] Lygia function inlining
- [ ] PNGine DSL generation
- [ ] Code view modal with syntax highlighting
- [ ] Copy to clipboard functionality

**Deliverable**: Can view and copy generated PNGine DSL

### Phase 4: Export (Week 4-5)

**Goal**: PNG export and sharing

- [ ] Integrate PNGine WASM compiler
- [ ] Download .pngine file
- [ ] Download .png file (compiled)
- [ ] URL-based state sharing
- [ ] Load from URL
- [ ] Preset "recipes" (pre-made stacks)

**Deliverable**: Can download working PNG, share via URL

### Phase 5: Polish (Week 5-6)

**Goal**: Production-ready UX

- [ ] Responsive design (mobile support)
- [ ] Keyboard shortcuts
- [ ] Undo/redo
- [ ] Card search and filtering
- [ ] Tooltips and help
- [ ] Loading states and error handling
- [ ] Analytics integration
- [ ] 50+ cards total

**Deliverable**: Production-ready composer app

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Time to first creation | < 30 seconds | User testing |
| Compositions per session | > 3 | Analytics |
| Export completion rate | > 50% | Analytics |
| Share link usage | > 20% of exports | Analytics |
| Return visitor rate | > 30% | Analytics |
| Mobile usage | > 20% | Analytics |

---

## Future Enhancements

### Phase 6+: Advanced Features

- **Audio reactivity**: Cards that respond to microphone input
- **Custom card creation**: Define new cards from WGSL snippets
- **Community gallery**: Browse and fork others' compositions
- **Animation timeline**: Keyframe parameter changes over time
- **Multi-pass rendering**: Feedback effects, post-processing
- **Texture inputs**: Use images as card inputs
- **3D mode**: Simple 3D scenes with SDF raymarching

### Integration Opportunities

- **Landing page demos**: Embed composer on pngine.dev
- **VS Code extension**: Card palette in editor sidebar
- **Figma plugin**: Generate shader PNGs for designs
- **Social cards**: Generate unique PNGs for social profiles

---

## Appendix: Lygia Function Reference

### Available WGSL Functions (254 total)

<details>
<summary>generative/ (15 functions)</summary>

- `cnoise` - Classic Perlin noise
- `snoise` - Simplex noise
- `voronoi` - Voronoi cells
- `fbm` - Fractal Brownian motion
- `random` - Pseudo-random
- `curl` - Curl noise
- `worley` - Worley noise
- `gerstnerWave` - Water waves
- ...

</details>

<details>
<summary>sdf/ (48 functions)</summary>

- `circleSDF` - Circle
- `rectSDF` - Rectangle
- `roundRectSDF` - Rounded rectangle
- `triSDF` - Triangle
- `starSDF` - Star
- `heartSDF` - Heart
- `polySDF` - Polygon
- `lineSDF` - Line segment
- `boxSDF` - 3D box
- `sphereSDF` - 3D sphere
- ...

</details>

<details>
<summary>color/palette/ (12 functions)</summary>

- `spectral` - Rainbow spectrum
- `heatmap` - Cold to hot
- `viridis` - Scientific
- `magma` - Volcanic
- `inferno` - Fire
- `plasma` - Purple-yellow
- `turbo` - Improved rainbow
- ...

</details>

<details>
<summary>color/ (40+ functions)</summary>

- `brightness` - Adjust brightness
- `contrast` - Adjust contrast
- `saturation` - Adjust saturation
- `hueShift` - Rotate hue
- `blend` - Blend modes
- `posterize` - Reduce colors
- `gamma` - Gamma correction
- ...

</details>

<details>
<summary>space/ (20+ functions)</summary>

- `tile` - Repeat pattern
- `mirror` - Reflect
- `rotate` - Rotation
- `scale` - Zoom
- `ratio` - Aspect ratio fix
- ...

</details>

<details>
<summary>filter/ (15+ functions)</summary>

- `gaussianBlur` - Gaussian blur
- `boxBlur` - Box blur
- `median` - Median filter
- `sharpen` - Sharpening
- `edge` - Edge detection
- ...

</details>

<details>
<summary>animation/ (10+ functions)</summary>

- `easing/*` - Easing functions
- `bounce` - Bounce interpolation
- ...

</details>

---

## Document History

| Date | Author | Changes |
|------|--------|---------|
| 2025-01-05 | Claude | Initial plan created |
