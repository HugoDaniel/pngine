# PNGine

[![npm](https://img.shields.io/npm/v/pngine)](https://www.npmjs.com/package/pngine)
[![license: CC0-1.0](https://img.shields.io/badge/license-CC0--1.0-blue)](LICENSE)

The WebGPU spec mapped 1:1 to S-expressions, packed in a PNG.
Self-contained, portable, tiny.

## How Small?

| Example | Bytecode | PNG with executor |
|---------|----------|-------------------|
| Triangle | 505 B | 4.5 KB |
| Rotating cube | 3.9 KB | 6.0 KB |
| Boids simulation | 4.9 KB | 6.2 KB |

The PNG contains everything: image, bytecode, and a WASM executor tailored to
what the program uses. No external runtime needed.

## Requirements

- **CLI / build from source**: [Zig](https://ziglang.org/) 0.16
- **npm package**: Node.js 18+
- **Browser runtime**: any browser with [WebGPU support](https://caniuse.com/webgpu)

## Install

```bash
npm install pngine
```

Or build from source. `build.zig.zon` declares two path dependencies,
`../wgslender` and `../SJON`, so clone all three side by side:

```bash
git clone https://github.com/HugoDaniel/wgslender.git
git clone https://github.com/HugoDaniel/SJON.git
git clone https://github.com/HugoDaniel/pngine.git
cd pngine
zig build          # → zig-out/bin/pngine
```

`https://git.hugodaniel.com/releases/pngine.git` is the same repository.

## Quick Start

**Compile a shader to PNG:**

```bash
pngine examples/simple_triangle.sjon -o triangle.png
```

**Run it in a browser:**

```javascript
import { pngine, play } from 'pngine';

const p = await pngine('triangle.png', {
  canvas: document.getElementById('canvas')
});
play(p);
```

The PNG is self-contained.

## Browser Runtime Profiles

The npm package ships focused runtime profiles:

| Profile | Import | Size (gzip) | Usage |
|---------|--------|-------------|-------|
| Viewer (default) | `pngine` | 16.9 KB | Production playback — worker + WASM inlined, zero external deps |
| Mini | `pngine/mini` | 3.2 KB | Tiny main-thread player for flat (pNGf) payloads — no Worker, no WASM |
| Mini (no audio) | `pngine/mini-no-audio` | 2.9 KB | Mini with the audio path dead-code-eliminated |
| Dev | `pngine/dev` | 18.5 KB | Full feature browser runtime (selectors, image init, shared fallback) |
| Core | `pngine/core` | 8.9 KB | Low-level dispatcher integration |
| Executor | `pngine/executor` | 0.9 KB | Payload/executor helper utilities |

**Viewer** inlines the WebWorker as a blob URL at bundle time. The WASM
executor is extracted from the PNG itself. Result: a single `.mjs` file with
no external runtime dependencies.

**Mini** interprets flat command buffers directly on the main thread. No
Worker, no OffscreenCanvas, no WASM. Requires `--flat` compiled PNGs.

Both accept byte buffers (`Uint8Array`/`ArrayBuffer`/`Blob`) as source, so a
PNG can be base64-inlined for a fully self-contained `.html` file.

See [npm/pngine/README.md](npm/pngine/README.md) for API details.

## How It Works

```
.sjon source
     |
     v
+----------+     +----------+     +--------------------+
| Compiler | --> | Bytecode | --> | PNG                |
|  (Zig)   |     |  (PNGB)  |     | + image            |
+----------+     +----------+     | + bytecode         |
                                  | + tailored executor|
                                  +--------------------+
                                           |
                                           v
                                  Browser: tiny loader (~2KB)
                                           |
                                           v
                                  Executor (WASM) --> WebGPU
```

The compiler does the heavy lifting. It validates the `.sjon` source against
the WebGPU schema, picks an executor build with only the plugins the program
needs, and bundles everything into the PNG.

The browser loader is minimal: it extracts the bytecode and executor from the
PNG, instantiates the WASM, and connects it to WebGPU.

## SJON Example

```sjon
(shader-module :name shader :code """
  @vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    var pos = array<vec2f, 3>(vec2f(0, 0.5), vec2f(-0.5, -0.5), vec2f(0.5, -0.5));
    return vec4f(pos[i], 0, 1);
  }

  @fragment fn fs() -> @location(0) vec4f {
    return vec4f(1, 0.5, 0, 1);
  }
""")

(render-pipeline :name pipe
  :layout auto
  (vertex :module shader :entry vs)
  (fragment :module shader :entry fs
    (target :format preferred-canvas-format)))

(render-pass :name draw
  (color-attachment :view context-current-texture :load-op clear :store-op store)
  :pipeline pipe
  (draw :vertex-count 3))

(frame :name main :perform [draw])
```

This compiles to 517 bytes of bytecode. `.sjon` is validated against the
WebGPU schema in [`schema/pngine.sjon`](schema/pngine.sjon); bare identifiers
(`shader`, `pipe`) are cross-references resolved at compile time. The full
authoring reference is [`docs/sjon-reference.md`](docs/sjon-reference.md);
[`examples/`](examples/README.md) holds over a hundred working programs.

Writing SJON with an LLM agent? Give it [`docs/llms.txt`](docs/llms.txt): a
compact reference with complete programs the test suite validates, at a URL it
can fetch whole:

```
https://raw.githubusercontent.com/HugoDaniel/pngine/main/docs/llms.txt
```

## CLI

| Command | Description |
|---------|-------------|
| `pngine <input>` | Compile to PNG with embedded bytecode + executor |
| `pngine compile <input>` | Compile to `.pngb` bytecode only |
| `pngine validate <input>` | Check source: syntax, semantics, WGSL |
| `pngine inspect <input>` | Inspect bytecode (`--deep` for runtime analysis) |
| `pngine embed <png> <pngb>` | Embed bytecode into existing PNG |
| `pngine extract <png>` | Extract bytecode from PNG |
| `pngine bundle <input>` | Package a shader and its assets into a ZIP bundle |
| `pngine list <zip\|png>` | List what a bundle or PNG carries |
| `pngine diff <a.png> <b.png>` | Pixel-compare two PNGs |

**Options:**

| Flag | Description | Default |
|------|-------------|---------|
| `-o, --output` | Output path | `<input>.png` |
| `-f, --frame` | Render actual frame via GPU | Off (1x1 transparent) |
| `-s, --size <WxH>` | Output dimensions | `512x512` |
| `-t, --time <sec>` | Animation time | `0.0` |
| `-m, --minify` | Minify WGSL shaders (~30% smaller shader text after compression) | Off |
| `--flat` | Compile to flat pNGf format (for mini player, no WASM) | Off |
| `--html` | Emit self-contained HTML with raw WebGPU JS (~1-3 KB) | Off |
| `--unpack` | With `--html`: skip the deflate pass — bigger, readable | Off |
| `--no-executor` | Don't embed executor (smaller, needs shared runtime) | Off |

**Examples:**

```bash
# Self-contained PNG
pngine shader.sjon

# Render 512x512 preview
pngine shader.sjon --frame

# Minified shaders for smallest payload
pngine compile shader.sjon -o output.pngb --minify

# Smaller PNG without executor (needs pngine.wasm at runtime)
pngine shader.sjon --no-executor

# Flat PNG for mini player (no WASM executor needed)
pngine shader.sjon --flat

# Self-contained HTML (~1-3KB, raw WebGPU JS, no runtime)
pngine shader.sjon --html -o shader.html

# Check bytecode is valid
pngine inspect output.png
```

**Piping:** every command takes `-` as an input (read stdin) or as `-o` (write
stdout). stdin is identified by its leading bytes — PNG, PNGB, ZIP, else SJON
source — so a pipeline needs no filenames. Diagnostics always go to stderr and
binary output is refused on a terminal, so `| jq` and `> file` stay clean.

```bash
pngine extract art.png | pngine inspect -
pngine compile - < shader.sjon > out.pngb     # -o defaults to stdout for `-`
curl -s "$url" | pngine validate - --json | jq
```

## Supported Platforms

The npm package includes native CLI binaries for:

| Platform | Architecture |
|----------|-------------|
| macOS | Apple Silicon (arm64), Intel (x64) |
| Linux | x64, arm64 |
| Windows | x64, arm64 |

Plus the WASM executor for browser execution: 13,331 bytes for the full build
(the build enforces a 13,600-byte cap); smaller variants ship when a payload
needs fewer plugins.

## Development

```bash
zig build              # CLI → zig-out/bin/pngine
zig build web          # WASM + JS for the browser tools (zig-out/playground/)
zig build npm          # cross-compile the npm platform binaries
zig build drift        # verify every generated artifact is current
```

Development happens in a private repository; the public repositories receive
release cuts — engine source, examples and reference docs, without the test
suite. Comments in the source cite that repository's development notes by
journal section (`§N`).

Reference docs:

- [`docs/sjon-reference.md`](docs/sjon-reference.md) — every `.sjon` form
- [`docs/llms.txt`](docs/llms.txt) — the compact reference for LLM agents; its programs run through `pngine validate` in `zig build drift`
- [`docs/architecture.md`](docs/architecture.md) — compiler, bytecode, runtime pipeline
- [`docs/abi.md`](docs/abi.md) — the frozen executor WASM↔JS ABI
- [`docs/publishing.md`](docs/publishing.md) — npm package layout and publishing
- [`CHANGELOG.md`](CHANGELOG.md)

## File Formats

| Extension | Description |
|-----------|-------------|
| `.sjon` | SJON source (schema-driven S-expressions) |
| `.pngb` | Compiled bytecode |
| `.png` | PNG with embedded bytecode (and optionally executor) |

## Features

- SJON compiler: schema-driven S-expressions validated against `schema/pngine.sjon`,
  with cross-references, bounded constant expressions and `(pass …)` / `(init …)` sugar
- PNGB bytecode with DEFLATE compression; PNG embedding and extraction
- Executor variants tailored to the plugins a payload uses, embedded by default
- Browser runtime (WebWorker + OffscreenCanvas) in six profiles; flat pNGf payloads
  for the WASM-free mini player; self-contained `--html` output
- Compute shaders with ping-pong buffer pools; WASM-generated data buffers
- Shape generators (cube, sphere, cone, torus, teapot, dragon)
- WGSL minification, `(constant …)` override specialisation, and advisory WGSL lint
  in `validate` (`--strict` turns warnings into exit 1)
- Native `--frame` rendering through wgpu-native (Metal); `pngine diff` for pixel
  comparison; `pngine inspect --deep` for WAMR-backed runtime diagnosis
- `-` on every command: stdin identified by its bytes, artifacts on stdout,
  diagnostics on stderr
- npm package with native CLI binaries for six platforms

## License

[CC0 1.0 Universal](LICENSE) — Public Domain
