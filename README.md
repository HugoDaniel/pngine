# PNGine

WebGPU shaders in a PNG. Self-contained, portable, tiny.

## How Small?

| Example | Bytecode | With Executor |
|---------|----------|---------------|
| Triangle | ~500 B | ~13 KB |
| Rotating cube | ~2 KB | ~14 KB |
| Boids simulation | ~8 KB | ~20 KB |

The PNG contains everything: image, bytecode, and a tailored WASM executor. No external runtime needed.

## Install

```bash
npm install pngine
```

Or build from source (requires Zig 0.14+):

```bash
git clone https://github.com/user/pngine
cd pngine
zig build
```

## Quick Start

**Compile a shader to PNG:**

```bash
pngine examples/simple_triangle.pngine -o triangle.png
```

**Run it in a browser:**

```javascript
import { pngine, play } from 'pngine';

const p = await pngine('triangle.png', {
  canvas: document.getElementById('canvas')
});
play(p);
```

That's it. The PNG is self-contained.

## How It Works

```
.pngine source
     │
     ▼
┌──────────┐     ┌──────────┐     ┌────────────────────┐
│ Compiler │ ──► │ Bytecode │ ──► │ PNG                │
│  (Zig)   │     │  (PNGB)  │     │ + image            │
└──────────┘     └──────────┘     │ + bytecode         │
                                  │ + tailored executor│
                                  └────────────────────┘
                                           │
                                           ▼
                                  Browser: tiny loader (~2KB)
                                           │
                                           ▼
                                  Executor (WASM) ──► WebGPU
```

The compiler does the heavy lifting. It analyzes your DSL, builds a tailored executor with only the plugins you need, and bundles everything into the PNG.

The browser loader is minimal—it extracts the bytecode and executor from the PNG, instantiates the WASM, and connects it to WebGPU.

## DSL Example

```wgsl
#wgsl shader {
  value="
    @vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
      var pos = array<vec2f, 3>(vec2f(0, 0.5), vec2f(-0.5, -0.5), vec2f(0.5, -0.5));
      return vec4f(pos[i], 0, 1);
    }

    @fragment fn fs() -> @location(0) vec4f {
      return vec4f(1, 0.5, 0, 1);
    }
  "
}

#renderPipeline main {
  vertex={ module=$wgsl.shader entryPoint="vs" }
  fragment={ module=$wgsl.shader entryPoint="fs" }
}

#renderPass draw {
  pipeline=$renderPipeline.main
  draw=3
}

#frame main {
  perform=[$renderPass.draw]
}
```

This compiles to ~500 bytes of bytecode.

## CLI

| Command | Description |
|---------|-------------|
| `pngine <input>` | Compile to PNG with embedded bytecode + executor |
| `pngine compile <input>` | Compile to `.pngb` bytecode only |
| `pngine check <input>` | Validate bytecode |
| `pngine embed <png> <pngb>` | Embed bytecode into existing PNG |
| `pngine extract <png>` | Extract bytecode from PNG |

**Options:**

| Flag | Description | Default |
|------|-------------|---------|
| `-o, --output` | Output path | `<input>.png` |
| `-f, --frame` | Render actual frame via GPU | Off (1x1 transparent) |
| `-s, --size <WxH>` | Output dimensions | `512x512` |
| `-t, --time <sec>` | Animation time | `0.0` |
| `--no-executor` | Don't embed executor (smaller, needs shared runtime) | Off |

**Examples:**

```bash
# Self-contained PNG (~13KB for triangle)
pngine shader.pngine

# Render 512x512 preview
pngine shader.pngine --frame

# Smaller PNG without executor (needs pngine.wasm at runtime)
pngine shader.pngine --no-executor

# Check bytecode is valid
pngine check output.png
```

## Development

```bash
# Run standalone tests (1,114 tests, parallel)
zig build test-standalone --summary all

# Full test suite (~5 min)
zig build test

# Build WASM + JS for browser
zig build web

# Build npm package (cross-compile all platforms)
zig build npm
```

See [CLAUDE.md](CLAUDE.md) for architecture details and coding conventions.

## File Formats

| Extension | Description |
|-----------|-------------|
| `.pngine` | DSL source |
| `.pngb` | Compiled bytecode |
| `.png` | PNG with embedded bytecode (and optionally executor) |

## Status

Complete:
- DSL compiler with macro-based syntax
- PNGB bytecode format with DEFLATE compression
- PNG embedding/extraction
- Browser runtime (WebWorker + OffscreenCanvas)
- npm package with native CLI for 6 platforms
- Tailored executor embedding

In progress:
- Native GPU rendering (currently stub backend for CLI `--frame`)
- Compute shader `#init` for procedural data

## License

MIT
