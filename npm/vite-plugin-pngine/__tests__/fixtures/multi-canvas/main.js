// Multiple canvases each with a different shader PNG
import shaderA from './shader_a.png'
import shaderB from './shader_b.png'
import shaderC from './shader_c.png'

const canvases = [
  { id: 'a', url: shaderA },
  { id: 'b', url: shaderB },
  { id: 'c', url: shaderC },
]

for (const { id, url } of canvases) {
  const canvas = document.getElementById(id)
  console.log(`Canvas ${id}:`, url.substring(0, 50))
}
