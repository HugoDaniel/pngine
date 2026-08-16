import { pngine, play, pause } from "pngine"

import triangleUrl from "./shaders/triangle.png"
import cubeUrl from "./shaders/cube.png"
import boidsUrl from "./shaders/boids.png"

// A 12-canvas scrolling gallery with visibility-driven playback — the
// pngine answer to webgpu-samples' multipleCanvases
// (docs/plans/wgpu-samples/23-multiple-canvases.md). The honest scale
// statement: pngine's unit is one instance = one canvas = one worker = one
// DEVICE, so a page budgets device count, not draw calls — ~12 canvases is
// comfortable everywhere, 200 shared-device canvases is upstream's design
// and out of this architecture's scope. Instances are constructed lazily on
// first intersection (defer pngine() itself, not just play()), paused when
// they leave the viewport (pause keeps time — scrolling back resumes;
// use stop() instead if reset-on-leave is wanted).

const urls = { triangle: triangleUrl, cube: cubeUrl, boids: boidsUrl }
const kinds = Object.keys(urls)
const gallery = document.querySelector(".gallery")

const instances = new Map() // canvas -> pngine instance (constructed)
const pending = new Map() // canvas -> url (not yet constructed)

for (let i = 0; i < 12; i++) {
  const kind = kinds[i % kinds.length]
  const card = document.createElement("div")
  card.className = "card"
  const title = document.createElement("h2")
  title.textContent = `${kind} #${Math.floor(i / kinds.length) + 1}`
  const canvas = document.createElement("canvas")
  canvas.width = 256
  canvas.height = 256
  card.append(title, canvas)
  gallery.append(card)
  pending.set(canvas, urls[kind])
}

// The multipleCanvases recipe: an IntersectionObserver maintains the
// visible set against the public play/pause API.
const io = new IntersectionObserver(
  (entries) => {
    for (const e of entries) {
      const canvas = e.target
      if (e.isIntersecting) {
        const url = pending.get(canvas)
        if (url) {
          pending.delete(canvas)
          pngine(url, { canvas })
            .then((p) => {
              instances.set(canvas, p)
              play(p)
            })
            .catch((err) => console.error("pngine init failed:", err))
        } else {
          const p = instances.get(canvas)
          if (p) play(p)
        }
      } else {
        const p = instances.get(canvas)
        if (p) pause(p)
      }
    }
  },
  { rootMargin: "64px" },
)
for (const canvas of pending.keys()) io.observe(canvas)
