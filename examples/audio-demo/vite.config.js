import { defineConfig } from "vite";
import { resolve } from "path";

const pngineRoot = resolve(__dirname, "../../npm/pngine/src");

export default defineConfig({
  define: { DEBUG: "true" },
  worker: { format: "es" },
  root: ".",
  server: {
    port: 5174,
    open: false,
    fs: { allow: [pngineRoot, "."] },
  },
  assetsInclude: ["**/*.wasm", "**/*.png"],
  resolve: {
    alias: {
      pngine: pngineRoot + "/index.js",
      "./worker.js": pngineRoot + "/worker.js",
      "./gpu.js": pngineRoot + "/gpu.js",
      "./anim.js": pngineRoot + "/anim.js",
      "./extract.js": pngineRoot + "/extract.js",
      "./audio.js": pngineRoot + "/audio.js",
      "./init.js": pngineRoot + "/init.js",
      "./loader.js": pngineRoot + "/loader.js",
      "./viewer-init.js": pngineRoot + "/viewer-init.js",
      "./viewer.js": pngineRoot + "/viewer.js",
      "./worker-viewer.js": pngineRoot + "/worker-viewer.js",
    },
  },
});
