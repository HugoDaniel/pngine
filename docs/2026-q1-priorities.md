# PNGine Q1 2026 Priorities

## Strategic Sort

### Tier 1: Launch Prerequisites
*Without these, nothing else matters*

| Priority | Item | Why |
|----------|------|-----|
| **1** | **Landing page** | You can't share what has no home. This blocks Product Hunt, Hacker News, everything. |
| **2** | **2-3 killer demos** | The landing page needs something to show. Demos ARE the marketing. |

### Tier 2: Virality Enablers
*These multiply your reach*

| Priority | Item | Why |
|----------|------|-----|
| **3** | **Video export (GIF/MP4)** | Most of the internet doesn't support WebGPU yet. If users can export to GIF, they can share ANYWHERE. |
| **4** | **Animated favicon demo** | This is your "holy shit" moment. Every website has a favicon. Every browser tab shows it. Make one animate. |

### Tier 3: Platform Growth
*These build the ecosystem*

| Priority | Item | Why |
|----------|------|-----|
| **5** | **Code editor (web)** | Enables the create→share→remix loop. But you can launch without it. |
| **6** | **Shadertoy import** | Instant content library. Thousands of shaders become PNGine demos overnight. |

### Tier 4: Platform Expansion
*These prove "runs everywhere"*

| Priority | Item | Why |
|----------|------|-----|
| **7** | **iOS/Android viewers** | Important for the "runs everywhere" story, but most people will first experience PNGine in a browser. Phase 2. |
| **8** | **ZIP support** | Useful but **dangerous**. It muddies the core message ("fits in a PNG"). Keep it quiet. |

---

## What's Missing (Added to List)

### Video Export (Critical)
```
PNGine shader → GIF/MP4 → Share on Twitter/Discord/anywhere
```
Without this, you're limited to platforms that support WebGPU. With this, every shader becomes shareable content. This is **higher priority than the code editor**.

### Shadertoy Import
There are ~100K shaders on Shadertoy. If you can import them:
- Instant content library
- Users bring their existing work
- "I exported my Shadertoy to a 15KB PNG" is a viral tweet

### One-Click Deploy
```
pngine deploy shader.png → https://pngine.dev/s/abc123
```
Hosted viewer URL. Share a link, not a file. This is how Shadertoy works.

---

## Demo Ideas: Ranked by Wow Factor

| Rank | Demo | Why It Works |
|------|------|--------------|
| **1** | **Animated favicon** | Every website, every browser tab. Universal applicability. |
| **2** | **Shader business card** | A PNG with your name + animated background. Fits in email signature. Personal. |
| **3** | **"Design your favicon"** | Grid tool positioned as "create animated favicon in 30 seconds". Useful + shareable. |
| **4** | **Album art generator** | Musicians are early adopters. Animated album covers. |
| **5** | **Generative profile picture** | Unique animated PFP per wallet/username. NFT-adjacent. |
| **6** | **"Shader in a QR code"** | QR code that, when scanned, runs the embedded shader. Mind-bending. |

The **grid design tool** is good but reframe it: it's not "a tool to make patterns", it's "a tool to make animated favicons/banners/backgrounds". The output is the hero, not the tool.

---

## Revised Roadmap

```
MONTH 1: Launch
├── Week 1-2: Landing page (hero demo, pitch, install instructions)
├── Week 3:   Animated favicon demo + "design your own" mini-tool
└── Week 4:   Video export (GIF at minimum)

MONTH 2: Virality
├── Week 1-2: Shadertoy import tool
├── Week 3:   One-click deploy (hosted viewer URLs)
└── Week 4:   Product Hunt / Hacker News launch

MONTH 3: Platform
├── Week 1-2: Code editor (web, basic)
├── Week 3-4: iOS viewer (prove "runs everywhere")
└── Ongoing:  Community building, tutorials
```

---

## The Critical Insight

The current list is **feature-focused**. But PNGine's gap isn't features—it's **distribution**.

| What we have | What we need |
|--------------|--------------|
| Code that works | A place to show it |
| 27 examples | 3 demos that spread |
| 6-platform npm | 0-platform virality |

**The landing page and favicon demo should take priority over everything else.** They're the difference between "cool project" and "thing people talk about."

---

## Landing Page Concept: The "PNG Gallery" Angle

What if the landing page itself IS the gallery?

```
pngine.dev
├── Hero: Animated shader (full viewport)
├── Grid: 20 clickable PNG demos (immediate "wow")
├── "Make your own" CTA → editor
└── "Get the PNG" → download + embed code
```

The page demonstrates the product by being made of the product. Every demo is a PNG. The landing page is a gallery. The gallery is the pitch.

---

## TL;DR Priority Order

1. **Landing page** (prerequisite for everything)
2. **Animated favicon demo** (your "holy shit" moment)
3. **Video export** (enables sharing everywhere)
4. **Shadertoy import** (instant content)
5. Code editor (growth)
6. iOS/Android viewers (expansion)
7. ZIP support (keep quiet)

The favicon demo alone could carry the launch. Make a website's favicon animate. Tweet it. Watch what happens.

---

## Original Feature List (User Proposed)

For reference, the original items proposed:

- [ ] Code editor for the web (WGSL + .pngine, syntax highlighting, mobile features)
- [ ] Awesome landing page (showcase, capture essence)
- [ ] Multiplatform viewers (iOS, Android)
- [ ] ZIP support enhancement (larger demos)
- [ ] Demos:
  - [ ] WebGPU favicon
  - [ ] Grid-based design tool in a single PNG
  - [ ] Other wow factor things

## Added Items (From Analysis)

- [ ] Video export (GIF/MP4) - **Critical for virality**
- [ ] Shadertoy import tool - **Instant content library**
- [ ] One-click deploy (hosted URLs) - **Frictionless sharing**
