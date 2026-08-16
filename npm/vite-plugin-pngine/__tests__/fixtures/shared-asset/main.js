// Two canvases sharing the same PNG asset
import shaderUrl from './shader.png'

// Canvas A uses the shader
const canvasA = document.getElementById('a')
console.log('Canvas A shader:', shaderUrl.substring(0, 50))

// Canvas B uses the exact same shader import
const canvasB = document.getElementById('b')
console.log('Canvas B shader:', shaderUrl.substring(0, 50))
