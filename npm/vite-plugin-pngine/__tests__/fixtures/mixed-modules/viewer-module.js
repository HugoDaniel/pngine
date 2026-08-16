// Simulates a module that would use the viewer profile
import viewerShaderUrl from './viewer_shader.png'

export function initViewer(canvas) {
  console.log('Viewer init:', viewerShaderUrl.substring(0, 50))
  console.log('Viewer canvas:', canvas.id, canvas.width, canvas.height)
}
