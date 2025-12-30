# PNGine Website Psychology Redesign Plan

> Applying Hook Model, SUCCESs Framework, and Information-Gap Theory to create an engaging, memorable, and effective website

---

## Executive Summary

The current PNGine website is technically accurate but psychologically inert. It fails to:
1. Create curiosity about what PNGine does
2. Make the value proposition memorable
3. Lower friction to first action
4. Build emotional connection with the target audience

This plan applies three psychological frameworks systematically:
- **Information-Gap Theory**: Create and satisfy curiosity
- **SUCCESs Framework**: Make messages sticky and memorable
- **Hook Model**: Enable low-friction action and investment

---

## Part 1: Audience Analysis

### Target Audience Profile

**Primary**: Shader artists, creative coders, demosceners
**Secondary**: WebGPU developers wanting portable demos
**Tertiary**: Curious developers who stumble upon PNGine

### The 5 Whys (Finding Internal Triggers)

```
Why would someone use PNGine?
  → To package and share WebGPU shaders

Why would they want to package shaders?
  → To make them portable, self-contained, easy to distribute

Why do they need portability?
  → So their work can run anywhere without setup

Why does that matter to them?
  → They want their creative work to be seen and appreciated

Why do they care about that?
  → INTERNAL TRIGGERS:
    - Pride in creation (positive)
    - Frustration with boilerplate (negative)
    - Fear of work being lost or unseen (negative)
```

### Audience Knowledge Levels

| Level | WebGPU Knowledge | Curiosity Strategy |
|-------|------------------|-------------------|
| **Novice** | Heard of it, never used | Prime with context before gaps |
| **Intermediate** | Used WebGPU, knows the pain | Highlight specific gaps in their workflow |
| **Expert** | Deep WebGPU experience | Appeal to "how is 500 bytes possible?" |

**Key Insight**: The curiosity-knowledge paradox means experts are MORE curious, not less. But novices need priming first.

---

## Part 2: Framework Application

### Information-Gap Strategy

**The Core Gaps to Create**:

| Gap | Question | Satisfaction |
|-----|----------|--------------|
| **Perceptual** | "Can PNGs actually move?" | Live demo proves it |
| **Size** | "How is a shader 500 bytes?" | Architecture explanation |
| **Technical** | "What's inside the PNG?" | Bytecode + chunk explanation |
| **Capability** | "What else can this do?" | Examples progression |

**Reference Point Elevation**:

Current visitor knowledge:
- PNGs are static images
- WebGPU requires significant boilerplate
- Portable graphics need big runtimes

Elevated reference points:
- "PNGs can contain executable shader code"
- "A triangle can be 500 bytes"
- "The executor fits in 15KB"

**Gap Creation Sequence (Landing Page)**:

```
1. "What if PNGs could move?"
   ↓ (perceptual curiosity)
   Live demo satisfies + creates next gap

2. "This is 487 bytes"
   ↓ (size curiosity)
   Architecture overview satisfies + creates next gap

3. "Here's the DSL that makes it possible"
   ↓ (technical curiosity)
   Code example satisfies + creates next gap

4. "What else can you build?"
   ↓ (capability curiosity)
   Examples/docs invitation
```

### SUCCESs Application

#### S - Simple

**Commander's Intent**: Self-contained GPU programs in minimal space

**Core Message Options** (choose one):
- "Shaders that fit in a PNG"
- "WebGPU bundles in a single file"
- "GPU art in 500 bytes"

**Forced Prioritization**: Every section must answer "does this support the core?"

#### U - Unexpected

**Schema Violations to Exploit**:

| Common Schema | PNGine Reality | Post-Dictable? |
|---------------|----------------|----------------|
| "PNGs are static images" | "This PNG runs shaders" | Yes: PNG allows custom chunks |
| "GPU programs are complex" | "500 bytes for a triangle" | Yes: Bytecode + compression |
| "Portable = big runtime" | "15KB executor included" | Yes: Tailored, minimal |
| "WebGPU needs boilerplate" | "3 lines of JS to play" | Yes: Abstraction layer |

**Break Then Repair Pattern**:
1. State the violation (break schema)
2. Show proof (live demo)
3. Explain why it works (repair schema)

#### C - Concrete

**Velcro Hooks to Add**:

| Abstract | Concrete |
|----------|----------|
| "Small file sizes" | "487 bytes" (specific number) |
| "Runs anywhere" | Live demo on the page |
| "Easy to use" | 3-line code snippet |
| "Self-contained" | "Fits in a favicon" |
| "Powerful" | Boids simulation running |

**Props and Demonstrations**:
- Live demos embedded in every section
- File size badges on examples
- Side-by-side: favicon icon vs rendered output
- Code → Result visualization

#### C - Credible

**Anti-Authority** (practitioner credibility):
- "Built for Inércia demoparty 2025"
- "The demo crashed, we fixed the engine"
- Not academic, not corporate—real use case

**Testable Credentials**:
- "Run `pngine check output.png` yourself"
- Live demos prove claims
- Specific byte counts (not "about 500")

**Sinatra Test**:
- "If it worked for a demoparty competition, it works for your project"
- "If a full boids simulation fits in 8KB..."

**Details That Build Trust**:
- "487 bytes" not "~500 bytes"
- "36 vertices" not "cube mesh"
- Version numbers, exact sizes

#### E - Emotional

**Identity Appeal** (most powerful):

Target identity: "Shader artists who hate boilerplate"

| Identity Statement | Implementation |
|-------------------|----------------|
| "For shader artists" | Use in headline/subhead |
| "Born from demoparty culture" | Origin story section |
| "Creative coding, not configuration" | Contrast with alternatives |

**Self-Interest (WIIFY)**:
- "YOU don't write boilerplate"
- "YOUR shaders run anywhere"
- "YOUR art fits in a favicon"

**Maslow's Hierarchy**:

| Level | Appeal |
|-------|--------|
| **Aesthetic** | Beautiful shader art showcase |
| **Self-actualization** | Creative expression enabled |
| **Transcendence** | Share art with the world |
| **Esteem** | Small file sizes = mastery signal |

**The Mother Teresa Effect**:
- Don't lead with statistics ("supports 20 opcodes")
- Lead with individual story (Inércia demo)
- One creator's journey > feature list

#### S - Stories

**Challenge Plot** (The Inércia Story):

```
Protagonist: Hugo + icid
Goal: Create a demo for Inércia demoparty
Obstacle: The demo crashed spectacularly
Low point: "It didn't work on most computers"
Resolution: Fixed and redesigned the engine
Outcome: Sharing PNGine with the world
```

This provides:
- Simulation: "This is how real people use it"
- Inspiration: "They overcame obstacles, I can too"
- Credibility: Battle-tested, not theoretical

**Story Placement**:
- Brief mention on landing page (1 paragraph)
- Full story in blog post (already written)
- Link between them

### Hook Model Application

**Note**: Documentation sites don't need full habit formation, but Hook elements improve conversion.

#### Trigger Strategy

| Type | Implementation |
|------|----------------|
| **Paid** | Not applicable (open source) |
| **Earned** | Demo shares, blog posts, conference mentions |
| **Relationship** | Community sharing creations |
| **Owned** | Newsletter (future), GitHub stars |
| **Internal (goal)** | "Need to share shader" → thinks of PNGine |

#### Action (B = MAT)

**Motivation** (created by previous sections):
- Curiosity satisfied but wanting more
- Identity resonance ("people like me use this")
- Emotional connection (Inércia story)

**Ability** (reduce friction):
- One-line install: `npm install pngine`
- Copy button on all code
- Minimal steps to first success

**Trigger** (clear call-to-action):
- "Try it now" button
- "Get started" link
- Visible next step

#### Variable Reward

| Type | PNGine Implementation |
|------|----------------------|
| **Hunt** | Discovering what's possible with small sizes |
| **Self** | Mastery of DSL, creating effects |
| **Tribe** | (future) Gallery, community |

#### Investment

| Investment Type | Implementation |
|-----------------|----------------|
| **Content** | Shaders they create |
| **Skill** | Learning the DSL |
| **Data** | Library of effects |

**Progressive Investment Staging**:
1. Light: Run the example (no account)
2. Medium: Modify the example
3. Heavy: Create own shader, share it

---

## Part 3: Page-by-Page Design

### Landing Page (index.smd)

**Goal**: Attention → Comprehension → First Action

#### Section 1: Hero

**Purpose**: Create curiosity gap + provide immediate satisfaction

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  [LIVE DEMO RUNNING]              "Shaders in a PNG"    │
│  (visual proof)                                         │
│                                    For shader artists    │
│  ┌──────────┐                     who hate boilerplate  │
│  │ 487      │                                           │
│  │ bytes    │                     [Get Started →]       │
│  └──────────┘                                           │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Elements**:
- **Headline**: "Shaders in a PNG" (simple, unexpected)
- **Subhead**: "For shader artists who hate boilerplate" (identity)
- **Live demo**: Running shader (concrete proof)
- **Size badge**: "487 bytes" (unexpected detail)
- **CTA**: "Get Started" (clear action)

**Psychology**:
- Unexpected: PNG running a shader
- Concrete: Live demo, specific size
- Emotional: Identity appeal in subhead
- Info-Gap: "How is this 487 bytes?" (implicit)

#### Section 2: What It Does

**Purpose**: Simple core message, satisfy "what is this?" gap

```
Bundle WebGPU shaders and pipeline configuration into a
single portable file. Run it anywhere with a tiny viewer.

One file. Your shaders. Any platform with WebGPU.
```

**Three Benefits** (concrete):
1. **Self-contained**: Everything in one PNG file
2. **Tiny**: Triangle in 500 bytes, boids in 8KB
3. **Portable**: Browser, native, anywhere WebGPU runs

#### Section 3: How Small

**Purpose**: Unexpected size claims with proof

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  Triangle        Rotating Cube      Boids Simulation    │
│  [LIVE DEMO]     [LIVE DEMO]        [LIVE DEMO]         │
│                                                         │
│  ~500 bytes      ~2 KB              ~8 KB               │
│  (bytecode)      (with animation)   (with compute)      │
│                                                         │
│  ────────────────────────────────────────────────────── │
│                                                         │
│  For comparison: This line of text is ~50 bytes.        │
│  A triangle shader is 10× that. Self-contained.         │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Psychology**:
- Unexpected: These sizes violate expectations
- Concrete: Running demos prove it
- Progressive revelation: Simple → Complex
- Human-scale statistic: "10× this sentence"

#### Section 4: How It Works

**Purpose**: Satisfy technical curiosity, build credibility

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│   .pngine file                                          │
│       │                                                 │
│       ▼                                                 │
│   ┌─────────┐     ┌─────────┐     ┌─────────┐          │
│   │Compiler │ ──► │Bytecode │ ──► │  PNG    │          │
│   │  (Zig)  │     │ (PNGB)  │     │+ image  │          │
│   └─────────┘     └─────────┘     └─────────┘          │
│                                        │                │
│                                        ▼                │
│                                   ┌─────────┐          │
│                                   │Executor │          │
│                                   │ (WASM)  │          │
│                                   └─────────┘          │
│                                        │                │
│                                        ▼                │
│                                   ┌─────────┐          │
│                                   │ WebGPU  │          │
│                                   └─────────┘          │
│                                                         │
│   The compiler does the heavy lifting.                  │
│   The executor just reads opcodes and calls WebGPU.     │
│   No surprises.                                         │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Psychology**:
- Concrete: Visual architecture
- Credible: Shows real components
- Simple: "Compiler does heavy lifting, executor is simple"

#### Section 5: Origin Story (Brief)

**Purpose**: Credibility + emotional connection

```
Born from Demoparty Culture

PNGine was built for Inércia 2025, a Portuguese demoparty.
The demo crashed spectacularly on the competition machine.
We fixed the engine. Now we're sharing it.

[Read the full story →]
```

**Psychology**:
- Story: Challenge plot (brief)
- Credible: Anti-authority (practitioners, not academics)
- Emotional: Vulnerability builds trust
- Info-Gap: "What happened?" → links to blog

#### Section 6: Try It Now

**Purpose**: Enable action with minimal friction

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│   npm install pngine                    [Copy]          │
│                                                         │
│   ─────────────────────────────────────────────────     │
│                                                         │
│   import { pngine, play } from 'pngine';                │
│                                                         │
│   const p = await pngine('shader.png', {                │
│     canvas: document.getElementById('canvas')           │
│   });                                                   │
│   play(p);                                              │
│                                                         │
│   ─────────────────────────────────────────────────     │
│                                                         │
│   That's it. Three lines to play a shader PNG.          │
│                                                         │
│   [Get Started →]     [See Examples →]                  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Psychology**:
- Ability: Copy button, minimal code
- Concrete: Actual code that works
- Unexpected: "Three lines" (schema violation for WebGPU)
- Clear action: Two paths forward

### Getting Started Page

**Goal**: Progressive revelation tutorial

#### Structure

```
1. SEE IT FIRST
   - Live demo of triangle
   - Reveal: "This is 487 bytes"
   - Gap creation: "Want to build this?"

2. INSTALLATION
   - npm install pngine
   - Verification: pngine --version

3. FIRST PROGRAM
   - Create triangle.pngine
   - Compile: pngine triangle.pngine -o triangle.png
   - Run in browser
   - Celebrate: "You just made a shader PNG!"

4. ADD ANIMATION
   - Add uniforms
   - Add time-based rotation
   - Run again
   - New capability revealed

5. NEXT STEPS
   - Add compute (gap for boids)
   - Explore DSL reference
   - See examples
```

**Key Change from Current**:
- Current: Installation → Code → Compile → Run
- New: **Result → Size → Gap → Installation → Code**

Show the destination before the journey.

### Documentation Index

**Goal**: Navigation + Inspiration

#### Structure

```
1. QUICK START (for returners)
   - Install command
   - Basic example
   - Key links

2. SIZE REFERENCE (unexpected reinforcement)
   | Example | Bytecode | With Executor |
   |---------|----------|---------------|
   | Triangle | 500B | 13KB |
   | Cube | 2KB | 14KB |
   | Boids | 8KB | 20KB |

3. GUIDES
   - Getting Started
   - Adding Animation
   - Compute Shaders
   - (future) Sharing Your Work

4. DSL REFERENCE
   - By category (shaders, resources, pipelines, execution)
   - Each with minimal working example

5. EXAMPLES GALLERY (future)
   - Community creations
   - Variable reward: "What will I discover?"
   - Investment opportunity: "I could build this"
```

---

## Part 4: Implementation Priorities

### Phase 1: Landing Page (Highest Impact)

**Why First**: Every visitor sees it. Currently losing most visitors immediately.

**Tasks**:
1. Design hero section with live demo
2. Write copy using SUCCESs principles
3. Implement size comparison section
4. Add brief origin story
5. Create low-friction "Try It" section

**Success Metrics**:
- Time on page increases
- Click-through to Getting Started increases
- Bounce rate decreases

### Phase 2: Getting Started Reorder

**Why Second**: Visitors who click through deserve a good experience.

**Tasks**:
1. Add "See the result first" section at top
2. Reorder to: Result → Gap → Install → Build
3. Add progressive complexity path
4. Improve "Next Steps" with clear gaps

### Phase 3: Documentation Enhancement

**Why Third**: Supports returning visitors and deeper exploration.

**Tasks**:
1. Add size reference table
2. Add minimal working examples to each reference
3. Create progression markers (beginner → advanced)
4. (future) Add examples gallery

---

## Part 5: Copy Guidelines

### Voice and Tone

**Voice**: Practitioner, not academic. Someone who uses this, not markets it.

**Tone**:
- Confident but not boastful
- Technical but accessible
- Enthusiastic but not hyperbolic

### Word Choice

| Avoid | Prefer |
|-------|--------|
| "Revolutionary" | "Fits in a PNG" |
| "Best-in-class" | "500 bytes" |
| "Seamless" | "Three lines" |
| "Leverage" | "Use" |
| "Solution" | "Tool" |

### Headline Patterns

| Pattern | Example |
|---------|---------|
| **Unexpected + Simple** | "Shaders in a PNG" |
| **Size + Concrete** | "A triangle in 500 bytes" |
| **Identity + Benefit** | "For shader artists who hate boilerplate" |
| **Question + Gap** | "What fits in a favicon?" |

### Anti-Patterns to Avoid

1. **Burying the lead**: Don't start with installation
2. **Feature lists without context**: Don't list opcodes
3. **Abstract benefits**: Don't say "portable" without showing
4. **Overselling**: Don't say "revolutionary"
5. **Jargon soup**: Don't assume WebGPU expertise

---

## Part 6: Verification Checklist

Before launching any page, verify:

### Curiosity Layer
- [ ] Clear, specific knowledge gap created
- [ ] Audience has context to perceive gap
- [ ] Resolution is provided (or linked)
- [ ] No curiosity fatigue (gaps are genuine)

### Stickiness Layer
- [ ] Core message is one sentence
- [ ] Contains unexpected element
- [ ] Details are concrete (numbers, demos)
- [ ] Credibility established (appropriate type)
- [ ] Emotional resonance (identity or self-interest)
- [ ] Story element present (challenge, connection, or creativity)

### Action Layer
- [ ] Clear call-to-action
- [ ] Minimal friction (copy buttons, one commands)
- [ ] Next step is obvious
- [ ] Investment opportunity present

### Integration Layer
- [ ] Curiosity → SUCCESs satisfaction → Action path flows
- [ ] No framework contradictions
- [ ] Progressive revelation maintained

---

## Appendix: Framework Quick Reference

### Information-Gap Theory

```
Reference Point (should know)
        ↑
        │ GAP (curiosity)
        │
Current Knowledge (actually know)

Key insight: Curiosity increases with knowledge.
Prime novices, challenge experts.
```

### SUCCESs Framework

```
S - Simple: Find core, express compactly
U - Unexpected: Break schemas, create gaps
C - Concrete: Tangible, sensory, specific
C - Credible: Anti-authority, testable, details
E - Emotional: Identity > self-interest
S - Stories: Challenge/Connection/Creativity
```

### Hook Model

```
TRIGGER → ACTION → VARIABLE REWARD → INVESTMENT
   ↑                                      |
   └──────────────────────────────────────┘

For docs: Focus on ACTION (low friction) and
INVESTMENT (learning, creating).
```

### Integration Flow

```
ATTENTION (Info-Gap) →
COMPREHENSION (SUCCESs) →
ACTION (Hook) →
RETENTION (Investment)
```

---

## Document History

| Date | Change |
|------|--------|
| 2024-12-30 | Initial plan created |
