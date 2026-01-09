import { defineConfig } from 'vite'
import { resolve } from 'path'

export default defineConfig({
  root: '.',
  server: {
    port: 5174,
    open: true,
    watch: {
      // Watch the dist folder for compiled bytecode changes
      ignored: ['!**/dist/**'],
    },
    fs: {
      // Allow serving files from the npm/pngine and zig-out directories
      allow: [
        '.',
        resolve(__dirname, '../../npm/pngine'),
        resolve(__dirname, '../../zig-out'),
      ],
    },
  },
  assetsInclude: ['**/*.wasm', '**/*.pngb', '**/*.png'],
  resolve: {
    alias: {
      // Use the main pngine package from the monorepo
      'pngine': resolve(__dirname, '../../npm/pngine/src/index.js'),
      './pngine.wasm': resolve(__dirname, '../../zig-out/demo/pngine.wasm'),
    }
  },
  build: {
    outDir: 'dist-web',
    rollupOptions: {
      input: resolve(__dirname, 'index.html'),
    }
  }
})
