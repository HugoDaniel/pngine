# PNGine Composer: The Alchemical Shader Deck

**Authoritative Design Document & Technical Specification v1.0**

---

## 1. The Manifesto: Post-Code Creation

Programming as a manual discipline is obsolete. The future of creation is not **syntax**, but **composition**. Humans act as Directors; the machine acts as the Architect.

**PNGine Composer** is not a code editor. It is a **deck-building game** for the GPU. Users do not "write shaders"; they draft decks of alchemical cards that transmute mathematics into visual art.

**Core Philosophy:**

1. **Tactile over Text:** If you can’t drag it, it doesn’t exist.
2. **Logic is Geometry:** Recursion, nesting, and math are visualized as physical attachments (Sockets).
3. **Performance is Currency:** Optimization is gamified as "Heat" (Mana Cost).
4. **The Asset is the Application:** The output PNG *is* the source code.

---

## 2. The Interaction Model: The Three Realms

We reject the "Preview in Middle" layout. It breaks the causal chain of the GPU pipeline. The interface overlays the cards on top of the live background (Glassmorphism), creating an immersive "heads-up display" over the artwork.

The workspace is divided into three distinct **Realms** (Columns), flowing Left to Right. This maps the mathematical Category Theory directly to the visual pipeline.

### Realm 1: SPACE (The Domain)

**"Where it happens."**

* **Math:** `UV -> UV` (Endofunctors).
* **Metaphor:** Warping the fabric of reality before matter exists.
* **Card Types:** Tile, Mirror, Rotate, Polar Coordinates, Fish-eye, Kaleido.
* **Behavior:** These cards modify the coordinate system for *everything* to their right.

### Realm 2: FORM (The Structure)

**"What exists."**

* **Math:** `UV -> Value` (Generators).
* **Metaphor:** Matter, density, and patterns.
* **Card Types:** Perlin Noise, Voronoi, SDF Shapes (Circle, Box), Gradients.
* **Behavior:** These stack like Photoshop layers. Each card has a **Blend Mode** (Add, Multiply, Mix) to interact with the Form cards below it.

### Realm 3: VIBE (The Codomain)

**"How it looks."**

* **Math:** `Value -> Color` and `Color -> Color`.
* **Metaphor:** Light, material properties, and camera lenses.
* **Card Types:**
* *Mappers:* Palettes (Rainbow, Heatmap), Thresholds.
* *Filters:* Glow, Dither, Pixelate, Chromatic Aberration, Vignette.



---

## 3. The Mechanic: Sockets & Attachments

*Solving the "Nesting" problem without node-graph spaghetti.*

We strictly prohibit "infinite nesting" in the main column view. Instead, we use a **Socket System** inspired by RPG equipment slots.

### A. Parameter Sockets (Runes)

Every parameter slider (e.g., "Radius" on a Circle Card) is a valid drop target.

* **Action:** User drags a "Sine Wave" card (LFO) onto the "Radius" slider.
* **Result:** The slider is replaced by a pulsating "Rune" icon. The radius is now animated.
* **Math:** The Generator calculates a float, which is piped into the Uniform of the parent card.

### B. Modifier Sockets (Equipment)

Complex math (Combinators) is handled via attachment slots on the cards themselves.

* **Scenario:** You want to mask Noise so it only appears inside a Circle.
* **Action:** Drag the "Circle SDF" card *onto* the body of the "Noise" card.
* **Result:** The Circle attaches as a "Badge" to the Noise card.
* **Logic:** The engine automatically creates a `Product (⊗)` relationship: `Noise * Circle`.

### C. Global Field Slots (The Table)

Effects that wrap the *entire* shader (Functors/Monads) sit in a special horizontal bar above the columns ("The Sky").

* **Example:** Dragging a **"Feedback"** card here turns on the `PrevFrame` buffer, creating trails for every object on screen.

---

## 4. Gamification: The Heat System

*Gamifying Optimization.*

Shaders are expensive. We teach optimization by treating GPU cycles as a resource cost.

### The "Heat" Metric (Mana)

Every card has a static **Heat Cost** based on its WGSL instruction weight.

* **Basic Math (Add/Mul):** 1 Heat.
* **Texture Sample:** 5 Heat.
* **Trigonometry (Sin/Cos):** 8 Heat.
* **Perlin Noise:** 20 Heat.
* **FBM (Loop):** 50+ Heat.

**The Game Loop:**

1. **Budget:** The user has a "Thermal Budget" (e.g., 100 Heat for 60fps mobile).
2. **Overheating:** Exceeding the budget turns the UI borders red and adds a "glitch/lag" visual effect to the UI (not the shader).
3. **Tiers:**
* **Common (White):** Low Heat (Basic shapes).
* **Rare (Blue):** Medium Heat (Textures, Filters).
* **Legendary (Gold):** High Heat (Complex Noise, Raymarching).



---

## 5. The Architecture: Category Theory Backend

The frontend is a game; the backend is a rigor-tested compiler.

### Data Structure: The Semantic Graph

We do not compile string-concatenations. We build a semantic graph based on your Plan B.

```typescript
type ShaderGraph = {
  space: PipelineStep[];   // UV transformations
  form: Layer[];           // Generators + Blends
  vibe: PostProcess[];     // Color mapping + Filters
  globals: GlobalEffect[]; // Feedback/Time buffers
}

type Layer = {
  id: string;
  generator: CardDefinition; // e.g., cnoise
  modifiers: Attachment[];   // Sockets (Masks, etc.)
  blendMode: 'add' | 'mul' | 'mix' | 'min' | 'max';
  params: Record<string, DynamicValue>; // Floats or linked LFO cards
}

```

### The Compilation Strategy: "The Uniform Atlas"

WebGPU limits bind groups. We cannot give every card its own bind group.
**Solution:** A massive, single `UniformBuffer` (The Atlas).

1. **Analysis:** The compiler walks the graph.
2. **Packing:** It collects all active floats, vec2s, and colors.
3. **Atlas Generation:** It packs them into a single `vec4<f32>` array.
4. **Injection:** The WGSL receives `uniforms.data[14].x` instead of `u_circle_radius`.

### Lygia Integration (Tree Shaking)

We do not include the whole library.

1. **Dependency Graph:** Each Card Definition lists its Lygia dependencies (e.g., `generative/cnoise`).
2. **Resolution:** The compiler recursively resolves dependencies (cnoise needs `math/mod289`).
3. **Stitching:** Only the required functions are injected into the preamble of the final WGSL string.

---

## 6. The Asset: The "Cartridge" PNG

The output mechanism is the viral engine of PNGine.

### Steganographic Save Files

We use a custom `tEXt` chunk in the PNG specification (key: `pngine_deck`).

1. **Serialize:** The `ShaderGraph` JSON is compressed (LZString) and embedded in the PNG metadata.
2. **Render:** The shader renders one frame at high res into the PNG pixel data.
3. **Distribution:** The user shares the image on Twitter/Discord.
4. **Loading:** Another user drags that image *from Twitter* onto the PNGine Editor.
5. **Hydration:** The app reads the `pngine_deck` chunk and instantly reconstructs the card stack.

**The image is the code.**

---

## 7. Implementation Roadmap

### Phase 1: The Engine (Weeks 1-3)

* **Focus:** No UI. Pure TypeScript logic.
* Implement the `ShaderGraph` to `WGSL` compiler.
* Implement the Lygia dependency resolver.
* Implement the "Uniform Atlas" packer.
* **Deliverable:** A unit test where a JSON object produces a valid, optimized WGSL string.

### Phase 2: The Table (Weeks 4-6)

* **Focus:** The Three-Realm Layout.
* Build the Drag & Drop system (using `@dnd-kit`).
* Implement the Space/Form/Vibe columns.
* Implement "Layer Blending" logic for the Form column.
* **Deliverable:** A working editor where dragging a card updates the canvas.

### Phase 3: The Sockets & Gamification (Weeks 7-9)

* **Focus:** UX depth.
* Implement "Card-on-Card" dropping for modifiers.
* Implement "Card-on-Slider" dropping for modulation.
* Implement the Heat/Cost calculator.
* **Deliverable:** Complex composition capabilities and visual feedback on performance.

### Phase 4: The Cartridge (Weeks 10-11)

* **Focus:** Export/Import.
* Implement PNG metadata writing/reading.
* Build the "Drag image to load" handler.
* **Deliverable:** Viral loop complete.

---

## 8. FAQ & Edge Cases

**Q: How do we handle Feedback (Time Travel) effects?**
**A:** The `Feedback` card is a "Global Field" card. When present, the engine switches the renderer to a **Double Buffered** pipeline (Ping-Pong). It allocates two textures (`Current`, `Previous`). The shader reads from `Previous` and writes to `Current`. At end of frame, they swap.

**Q: What if the user creates an infinite loop?**
**A:** The `Fix` (Recursion) card must be hard-capped in the engine. It compiles to an unrolled `for` loop with a maximum iteration count (e.g., 8). We do not allow true `while` loops to prevent GPU hangs.

**Q: How do custom textures (images) work?**
**A:** A "Texture" card in the Form column. The user uploads an image, which is uploaded to a GPU Texture. *Constraint:* For the PNG Cartridge to work, the user texture must be base64 encoded into the save data (bloating the file) OR referenced via URL (breaking if offline). **Decision:** V1 supports URL references only.

**Q: Is this Turing Complete?**
**A:** No, and it shouldn't be. It is "Art Complete." We prioritize visual expression over algorithmic computation.

---

## 9. Visual Style Guide

* **Aesthetic:** Cyber-Occult / Solarpunk.
* **Cards:** Dark glass morphism, neon borders colored by category (Space=Blue, Form=Green, Vibe=Pink).
* **Wires:** When a card modulates another (Socket), render a bezier curve connecting them when hovered.
* **Preview:** The background IS the preview. The UI floats.

This approach resolves the conflict between math and play. It respects the underlying Category Theory by giving it a physical form, while the UI mimics the familiarity of Hearthstone or Slay the Spire.
