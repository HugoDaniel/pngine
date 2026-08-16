// Simulates mixing viewer and dev profiles on the same page
// Each module imports its own PNG and has its own initialization logic.
import { initViewer } from './viewer-module.js'
import { initDev } from './dev-module.js'

const viewerCanvas = document.getElementById('viewer-canvas')
const devCanvas = document.getElementById('dev-canvas')

initViewer(viewerCanvas)
initDev(devCanvas)
