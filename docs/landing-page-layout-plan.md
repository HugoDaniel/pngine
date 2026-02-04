# PNGine Landing Page Layout Plan

> Based on website-psychology-plan.md analysis and logo design language

---

## Logo Design Language

The PNGine logo establishes the visual identity:
- **Pixel-art aesthetic** - speaks directly to demoscene/creative coding culture
- **Color palette**: Orange (#E85D4C) for text, Purple-blue (#6A5ACD) for the grid
- **The "P" negative space** - clever use of the grid to form a shape
- **Retro-modern hybrid** - pixel art with clean proportions

---

## Recommended Layout: "Pixel-Grid Hero"

```
┌─────────────────────────────────────────────────────────────────────────┐
│  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│  ░  [LOGO]                                          [GitHub] [Docs]  ░ │
│  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│                                                                         │
│   ┌───────────────────────────────────┐                                │
│   │                                   │      Shaders in a PNG          │
│   │                                   │                                │
│   │    [LIVE SHADER DEMO]             │      For shader artists        │
│   │    ~~~~~~~~~~~~~~~~~~~~~~~~       │      who hate boilerplate      │
│   │    ~~~~~~~~~~~~~~~~~~~~~~~~       │                                │
│   │    ~~~~~~~~~~~~~~~~~~~~~~~~       │      ┌──────────┐              │
│   │                                   │      │  487     │              │
│   │                                   │      │  bytes   │              │
│   └───────────────────────────────────┘      └──────────┘              │
│                                                                         │
│                                              [Get Started →]           │
│                                                                         │
│   ─────────────────────────────────────────────────────────────────────│
│                                                                         │
│              ↓ How is 500 bytes possible?                              │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Section Structure

### Section 1: Hero
- Live demo (WebGPU canvas, auto-playing)
- Headline: "Shaders in a PNG"
- Subhead: "For shader artists who hate boilerplate"
- Size badge (487 bytes)
- Primary CTA: "Get Started"

### Section 2: Size Gallery
Scroll anchor: "How small?"

Three demo cards in responsive grid:
- Triangle [demo] "~500 bytes"
- Rotating Cube [demo] "~2 KB"
- Boids Simulation [demo] "~8 KB"

Human-scale comparison: "This paragraph is ~200 bytes."

### Section 3: Architecture
Scroll anchor: "How?"

Pixel-art style flow diagram:
```
.pngine → Compiler → Bytecode → PNG → Executor → WebGPU
```

One-line explanation: "Compiler does heavy lifting. Executor just plays."

### Section 4: Origin Story (brief)
Quote block with challenge plot:
"Built for Inércia 2025. Demo crashed. We fixed the engine."

[Read the full story →]

### Section 5: Try It Now
- Install: `npm install pngine` [Copy]
- Code snippet (3 lines) [Copy]
- "That's it. Three lines to play a shader PNG."
- Two CTAs: [Get Started] [See Examples]

### Footer
- Logo (small)
- Quick links
- GitHub star badge

---

## Design System

### Colors (derived from logo)

```css
--primary: #6A5ACD;      /* Purple-blue from grid */
--accent: #E85D4C;       /* Orange from "PNGINE" */
--bg-dark: #0F0F1A;      /* Deep purple-black */
--bg-card: #1A1A2E;      /* Card backgrounds */
--text: #F0F0F0;         /* Primary text */
--text-muted: #8888AA;   /* Secondary text */
--success: #4ADE80;      /* Success states */
```

### Typography

- **Headline**: Geometric sans-serif or pixel font (Space Grotesk / Press Start 2P)
- **Body**: Clean sans-serif (Inter, system-ui)
- **Code**: JetBrains Mono or Fira Code
- **Size badges**: Monospace with LED-style treatment

### Spacing Scale

```css
--space-xs: 0.25rem;   /* 4px */
--space-sm: 0.5rem;    /* 8px */
--space-md: 1rem;      /* 16px */
--space-lg: 2rem;      /* 32px */
--space-xl: 4rem;      /* 64px */
--space-2xl: 8rem;     /* 128px */
```

---

## Key Implementation Details

### Hero Demo Requirements
- Use simplest shader that looks good (plasma, noise gradient, rotating cube)
- Fallback for non-WebGPU browsers: static image with "WebGPU required" overlay
- Pre-warm WebGPU to avoid blank canvas on load

### Size Badge Treatment
- Styled like a pixel-art element or LED display
- Position: floating between demo and CTA
- Specific number "487" (not "~500") builds credibility

### Progressive Scroll
- Each section answers the question created by previous section
- Scroll anchors or smooth scroll indicators
- "How is 500 bytes possible?" creates explicit curiosity

### Mobile-First
- Hero stacks vertically: Demo → Badge → Headline → CTA
- Demo canvas full-width on mobile
- Size gallery becomes 1-column or carousel
- Code blocks scroll horizontally

---

## Success Criteria

Based on psychology plan, the landing page must:

1. **Create perceptual gap** within 2 seconds (live demo)
2. **Violate size expectations** prominently (487 bytes badge)
3. **Establish identity resonance** in first viewport
4. **Enable action** with minimal friction (copy buttons)
5. **Build credibility** through specificity (exact numbers)

---

## File Structure

```
website/
├── index.html
├── styles/
│   ├── variables.css
│   ├── base.css
│   ├── components.css
│   └── sections.css
├── scripts/
│   └── main.js
└── assets/
    ├── logo.png
    └── shaders/
        ├── triangle.png
        ├── cube.png
        └── boids.png
```
