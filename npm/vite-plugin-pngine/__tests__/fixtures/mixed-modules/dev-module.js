// Simulates a module that would use the dev profile
import devShaderUrl from './dev_shader.png'

export function initDev(canvas) {
  console.log('Dev init:', devShaderUrl.substring(0, 50))
  console.log('Dev canvas:', canvas.id, canvas.width, canvas.height)
}
