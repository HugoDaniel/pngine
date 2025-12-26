import { defineConfig } from 'vite'

export default defineConfig({
  root: 'demo',
  publicDir: '../zig-out/web',
  server: {
    port: 5173,
    open: false,
  },
  build: {
    outDir: '../dist-demo',
  },
})
