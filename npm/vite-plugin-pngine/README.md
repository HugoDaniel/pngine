# vite-plugin-pngine

Vite plugin for bundling [PNGine](https://github.com/HugoDaniel/pngine) apps into single HTML files.

One `pnginePlugin()` call configures everything — dev mode aliases, WASM serving, DEBUG flag, and production single-file output.

## Install

```bash
npm install -D vite-plugin-pngine
```

## Usage

```js
// vite.config.js
import { defineConfig } from "vite"
import { pnginePlugin } from "vite-plugin-pngine"

export default defineConfig({
  plugins: [pnginePlugin()],
})
```

```html
<!-- index.html -->
<canvas id="canvas" width="512" height="512"></canvas>
<script type="module" src="./main.js"></script>
```

```js
// main.js
import { pngine, play } from "pngine"
import shaderUrl from "./shader.png"

const p = await pngine(shaderUrl, { canvas: document.getElementById("canvas") })
play(p)
```

Build with `vite build` — the output is a single `index.html` with all JS, CSS, and PNG assets inlined.

## How PNG Inlining Works

Use standard Vite static imports for your PNG files:

```js
import shaderUrl from "./shader.png"
```

The plugin sets `assetsInlineLimit` to inline all assets as base64 data URLs. The PNGine viewer's `fetch()` handles data URLs natively. No special query parameters needed.

> **Note**: Runtime string literals like `pngine("shader.png", ...)` won't be inlined by Vite. Always use static imports for single-file builds.

## Dev Mode

In development (`vite` / `vite dev`), the plugin:

- Sets up aliases so PNGine's internal modules resolve correctly
- Serves `.wasm` files with the correct `Content-Type`
- Enables `DEBUG` mode for PNGine's debug logging

No manual alias configuration needed.

## `.sjon` Source Compilation

Optionally compile `.sjon` source files to PNG at build time:

```js
// vite.config.js
pnginePlugin({ compile: true })
```

```js
// main.js
import shaderUrl from "./shader.sjon?png"
```

Requires the `pngine` CLI to be available (`npm install pngine`). `.sjon` is a
first-class CLI input. In dev mode, files are compiled on demand with caching.
HMR is supported — changing a `.sjon` file triggers recompilation.

## Configuration

```ts
interface PnginePluginOptions {
  /** Enable single-file HTML output in production. @default true */
  singleFile?: boolean

  /** Remove Vite module loader polyfill. @default true */
  removeViteModuleLoader?: boolean

  /** Delete inlined files from output dir. @default true */
  deleteInlinedFiles?: boolean

  /** Compile .sjon source files via CLI. @default false */
  compile?: boolean

  /** CLI compile options (when compile: true). */
  compileOptions?: {
    /** Embed executor WASM in PNG. @default true */
    embed?: boolean
    /** Minify WGSL shaders. @default true in production */
    minify?: boolean
  }
}
```

### `singleFile`

When `true` (default), the production build inlines all JS and CSS into the HTML file. Set to `false` if you want standard Vite output with separate files.

### `deleteInlinedFiles`

When `true` (default), inlined JS/CSS files are removed from the output directory. Set to `false` to keep them (useful for source maps or debugging).

### `compile`

When `true`, `.sjon` source files can be imported with the `?png` query. The plugin compiles them to PNG using the `pngine` CLI. Results are cached by file modification time.

## Examples

See the `examples/` directory:

- **`vite-basic/`** — Minimal single-file PNGine app
- **`vite-gallery/`** — Multiple shaders in a gallery layout, CSS, single HTML output

## How It Works

The plugin is split into two Vite plugins:

1. **`vite-plugin-pngine:config`** (enforce: `"pre"`) — Sets Vite build config for asset inlining, configures dev aliases, adds WASM middleware
2. **`vite-plugin-pngine:build`** (enforce: `"post"`) — Handles `.sjon` compilation and the `generateBundle` hook that inlines JS/CSS into HTML

The singlefile logic is adapted from [vite-plugin-singlefile](https://github.com/nicolo-ribaudo/vite-plugin-singlefile):
- JS: `<script src="...">` → `<script>` with inlined code
- CSS: `<link href="...">` → `<style>` with inlined styles
- Assets: Vite's `assetsInlineLimit` converts them to data URLs

## License

CC0-1.0

## Compatibility

Vite 5.4.11+, 6, 7, and 8. Node 18+.
