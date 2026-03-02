import { defineConfig } from 'vite'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))

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
  plugins: [{
    name: 'wasm-mime-type',
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        if (req.url && req.url.endsWith('.wasm')) {
          res.setHeader('Content-Type', 'application/wasm');
        }
        next();
      });
    },
  }],
  assetsInclude: ['**/*.wasm', '**/*.pngb', '**/*.png'],
  resolve: {
    alias: [
      // Match subpath entrypoints first.
      { find: 'pngine/viewer', replacement: resolve(__dirname, '../../npm/pngine/src/viewer.js') },
      { find: 'pngine/dev', replacement: resolve(__dirname, '../../npm/pngine/src/dev.js') },
      { find: 'pngine/core', replacement: resolve(__dirname, '../../npm/pngine/src/core.js') },
      { find: 'pngine/executor', replacement: resolve(__dirname, '../../npm/pngine/src/executor.js') },
      // Canonical default profile.
      { find: 'pngine', replacement: resolve(__dirname, '../../npm/pngine/src/index.js') },
      { find: 'pngine-bundle', replacement: resolve(__dirname, '../../npm/pngine/dist/viewer.mjs') },
      { find: './pngine.wasm', replacement: resolve(__dirname, '../../zig-out/playground/pngine.wasm') },
    ],
  },
  build: {
    outDir: 'dist-web',
    rollupOptions: {
      input: resolve(__dirname, 'index.html'),
    }
  }
})
