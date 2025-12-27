import { defineConfig } from 'vite'
import { resolve } from 'path'

export default defineConfig({
  root: 'zig-out/demo',
  server: {
    port: 5173,
    open: false,
  },
  build: {
    outDir: '../../dist-demo',
  },
  resolve: {
    alias: {
      // Fallback to npm/pngine/src for development
      './pngine.js': resolve(__dirname, 'npm/pngine/src/index.js'),
      './init.js': resolve(__dirname, 'npm/pngine/src/init.js'),
      './worker.js': resolve(__dirname, 'npm/pngine/src/worker.js'),
      './gpu.js': resolve(__dirname, 'npm/pngine/src/gpu.js'),
      './anim.js': resolve(__dirname, 'npm/pngine/src/anim.js'),
      './extract.js': resolve(__dirname, 'npm/pngine/src/extract.js'),
      './loader.js': resolve(__dirname, 'npm/pngine/src/loader.js'),
    }
  }
})
