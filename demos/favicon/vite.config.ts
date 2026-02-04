import { defineConfig } from 'vite';
import { resolve } from 'path';

export default defineConfig({
    server: {
        port: 5174,
        fs: {
            allow: ['../../..'] // Allow access to project root (npm/pngine/src)
        },
        headers: {
            'Cross-Origin-Opener-Policy': 'same-origin',
            'Cross-Origin-Embedder-Policy': 'require-corp'
        }
    },
    worker: {
        format: 'es'
    },
    resolve: {
        alias: {
            'pngine': resolve(__dirname, '../../npm/pngine/src/index.js'),
            './pngine.wasm': resolve(__dirname, '../../zig-out/playground/pngine.wasm')
        }
    },
    root: '.',
    publicDir: 'dist'
});
