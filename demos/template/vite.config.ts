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
    alias: {
      // Use the main pngine package from the monorepo
      'pngine': resolve(__dirname, '../../npm/pngine/src/index.js'),
      './pngine.wasm': resolve(__dirname, '../../zig-out/playground/pngine.wasm'),
    }
  },
  build: {
    outDir: 'dist-web',
    rollupOptions: {
      input: resolve(__dirname, 'index.html'),
    }
  }
})
