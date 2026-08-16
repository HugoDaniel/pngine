# PNGine NPM Package

The WebGPU spec mapped 1:1 to S-expressions, packed in a PNG.

## Runtime Profiles

PNGine ships six browser-facing profiles:

| Profile | Import | Purpose |
| --- | --- | --- |
| Viewer (default) | `pngine` or `pngine/viewer` | Lean production player for PNG payloads with embedded executor |
| Dev | `pngine/dev` | Full feature surface for iteration and debugging |
| Core | `pngine/core` | Low-level runtime API (dispatcher-centric) |
| Executor | `pngine/executor` | Advanced payload/executor helper API |
| Mini | `pngine/mini` | Tiny main-thread player for flat (pNGf) payloads |
| Mini (no audio) | `pngine/mini-no-audio` | Same as Mini with audio support stripped |

## Self-Contained Playback

Every profile is designed to minimize external dependencies at runtime:

| Profile | Worker | WASM source | External files needed |
| --- | --- | --- | --- |
| **Viewer** | Blob-inlined | Extracted from PNG (embedded executor) | None — PNG carries its own executor |
| **Dev** | Blob-inlined | PNG or external fallback (`wasmUrl`) | Optional `pngine.wasm` if PNG lacks executor |
| **Mini** | None (main thread) | None (pNGf is interpreted directly) | None |
| **Core** | None (you manage it) | You provide it | You manage everything |

**What this means:** The viewer and mini profiles are each a single `.mjs` file
with zero external runtime dependencies. The PNG file is the only input — it
carries both the bytecode and (for viewer) the WASM executor.

### Single-file HTML

Both viewer and mini accept `ArrayBuffer | Uint8Array | Blob` as source (not
just URLs), so a PNG can be base64-encoded inline for a fully self-contained
`.html` file:

```html
<canvas id="c" width="512" height="512"></canvas>
<script type="module">
  import { pngine, play } from 'pngine'; // or inline viewer.mjs directly
  const data = Uint8Array.from(atob('iVBOR...'), c => c.charCodeAt(0));
  const p = await pngine(data.buffer, { canvas: document.getElementById('c') });
  play(p);
</script>
```

For the smallest possible output, use `pngine/mini` with a `--flat` compiled
PNG, or use `pngine --html` which bypasses all JS runtimes entirely and emits
raw WebGPU API calls (~1–3 KB).

## Viewer API (Default)

### Usage scenario

Use viewer for normal playback of PNG payloads generated with the default embedded executor.

### Input contract

```ts
pngine(
  source: string | Uint8Array | ArrayBuffer | Blob,
  options: {
    canvas: HTMLCanvasElement;
    debug?: boolean;
    dpr?: number;
    onError?: (err: Error) => void;
  }
)
```

Notes:
- `canvas` is required.
- `source` can be URL or byte data.
- `wasmUrl`, selector strings, and `HTMLImageElement` sources are dev-only features.
- Viewer keeps wasm-in-wasm runtime support enabled by default.
- Viewer supports runtime interactivity via `draw(...uniforms)`, `setUniform`, `setUniforms`, and `getUniforms`.

### Example

```js
import { pngine, play } from 'pngine';

const canvas = document.getElementById('canvas');
const p = await pngine('/assets/triangle.png', { canvas });
play(p);
```

## Dev API

Dev profile keeps the full feature set:
- Selector and image-element initialization paths.
- Shared executor fallback (`wasmUrl`) for payloads without embedded executor.
- Executor helper exports on the same entrypoint.

```js
import { pngine, parsePayload } from 'pngine/dev';
```

## Core API

Core profile is for integrators who already manage device/context/lifecycle.

```js
import { createCoreDispatcher, configureCanvas, getDevice } from 'pngine/core';
```

## Executor API

Advanced helpers for payload parsing and manual executor loading.

```js
import { parsePayload, createExecutor, getExecutorImports } from 'pngine/executor';
```

## Mini API

Tiny player for `--flat` compiled payloads (pNGf format). Runs entirely on the
main thread — no Worker, no OffscreenCanvas, no WASM executor.

```js
import { miniPngine } from 'pngine/mini';

const canvas = document.getElementById('canvas');
const inst = await miniPngine(canvas, '/shader-flat.png', { autoplay: true });

inst.play();
inst.pause();
inst.stop();
inst.destroy();
inst.time;       // current time in seconds
inst.isPlaying;  // animation state
```

`source` accepts `string` (URL), `ArrayBuffer`, or `Uint8Array`.

Same API without the Sointu audio player, ~600 B smaller — the audio path is
dead-code-eliminated rather than branched around, so a pNGa payload's audio
chunk is simply ignored:

```js
import { miniPngine } from 'pngine/mini-no-audio';
```

## Compiler & Authoring Assets

The package also ships the in-browser compiler and the SJON schema, so an
editor can consume the whole engine from node_modules:

```js
import { createCompiler } from 'pngine/compiler';

// The compiler WASM ships in the package; serve it and pass its URL.
const compiler = await createCompiler('/pngine-compiler.wasm');
const { pngb, errors } = compiler.compile(sjonSource);
```

| Subpath | File | What it is |
| --- | --- | --- |
| `pngine/compiler` | `src/compiler.js` | Browser compiler wrapper (`createCompiler(wasmUrl)`) |
| `pngine/compiler-wasm` | `wasm/pngine-compiler.wasm` | The compiler WASM (~1.6 MB) |
| `pngine/worker` | `src/worker.js` | The render WebWorker entry (module worker) |
| `pngine/schema/pngine.sjon` | `schema/pngine.sjon` | The SJON WebGPU schema, importable as text |

The unbundled `src/` tree ships too, so bundlers can reach individual modules
(e.g. a `new Worker(new URL(...))` pointed at `pngine/src/worker.js`).

## Bundle Sizes

Measured by `node npm/pngine/scripts/bundle.cjs`; `zig build drift` checks
this table against the bundler's budgets.

<!-- BUNDLE-TABLE: bundle set checked against scripts/bundle.cjs by `zig build drift` -->

| File | Raw | Gzip |
| --- | --- | --- |
| `viewer.mjs` | 49.0 KB | 16.9 KB |
| `dev.mjs` | 53.5 KB | 18.5 KB |
| `core.mjs` | 26.0 KB | 8.9 KB |
| `executor.mjs` | 1.9 KB | 0.9 KB |
| `mini.mjs` | 7.0 KB | 3.2 KB |
| `mini-no-audio.mjs` | 6.3 KB | 2.9 KB |
| `index.cjs` (Node stub) | 2.8 KB | - |

## Build Commands

```bash
# Production bundles
npm run build

# Debug bundles (source maps, DEBUG=true)
npm run build:debug
```

## Dist Files

```text
dist/
├── viewer.mjs
├── dev.mjs
├── core.mjs
├── executor.mjs
├── mini.mjs
├── mini-no-audio.mjs
├── index.cjs         # Node CJS stubs
├── index.mjs         # Node ESM stubs
├── index.d.ts        # default (viewer) types
├── viewer.d.ts
├── dev.d.ts
├── core.d.ts
├── executor.d.ts
├── mini.d.ts
└── mini-no-audio.d.ts
```

## CLI and Native Binaries

The package also ships the `pngine` CLI via optional native binaries:

| Package | Platform |
| --- | --- |
| `@pngine/darwin-arm64` | macOS Apple Silicon |
| `@pngine/darwin-x64` | macOS Intel |
| `@pngine/linux-x64` | Linux x64 |
| `@pngine/linux-arm64` | Linux ARM64 |
| `@pngine/win32-x64` | Windows x64 |
| `@pngine/win32-arm64` | Windows ARM64 |

## License

CC0-1.0
