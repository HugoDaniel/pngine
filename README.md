# PNGine

A WebGPU bytecode engine that compiles shader DSL into compact bytecode (PNGB) for embedding in PNGs and executing in browsers.

**Goal**: Shader art that fits in a PNG file, executable in any browser.

## Features

- **DSL Compiler**: Macro-based syntax for defining WebGPU resources and pipelines
- **Bytecode Format**: Compact PNGB format (~400 bytes for simple triangle)
- **PNG Embedding**: Embed bytecode in `pNGb` ancillary chunk with DEFLATE compression
- **Minimal Output**: Default 1x1 transparent PNG container (~500-700 bytes with bytecode)
- **Preview Rendering**: Optional GPU rendering for preview images

## Installation

Requires [Zig](https://ziglang.org/) 0.14+ (master branch).

```bash
git clone https://github.com/user/pngine
cd pngine
zig build
```

## Quick Start

```bash
# Create a minimal PNG with embedded bytecode (~700 bytes)
./zig-out/bin/pngine examples/simple_triangle.pngine -o triangle.png

# Render a 512x512 preview image
./zig-out/bin/pngine examples/simple_triangle.pngine -o preview.png --frame

# Check that bytecode is valid
./zig-out/bin/pngine check triangle.png
```

## CLI Reference

### Commands

| Command | Description |
|---------|-------------|
| `pngine <input>` | Create PNG with embedded bytecode (default) |
| `pngine compile <input>` | Compile source to `.pngb` bytecode |
| `pngine check <input>` | Validate bytecode execution |
| `pngine render <input>` | Alias for default render command |
| `pngine embed <png> <pngb>` | Embed bytecode into existing PNG |
| `pngine extract <png>` | Extract bytecode from PNG |

### Render Options

| Flag | Description | Default |
|------|-------------|---------|
| `-o, --output <path>` | Output PNG path | `<input>.png` |
| `-f, --frame` | Render actual frame via GPU | Off (1x1 transparent) |
| `-s, --size <WxH>` | Output dimensions (with --frame) | `512x512` |
| `-t, --time <seconds>` | Time value for animation | `0.0` |
| `-e, --embed` | Embed bytecode in PNG | On |
| `--no-embed` | Don't embed bytecode | Off |

### Examples

```bash
# Create minimal PNG with embedded bytecode (~500 bytes)
pngine shader.pngine

# Render 512x512 preview with embedded bytecode
pngine shader.pngine --frame

# Render at 1080p
pngine shader.pngine --frame -s 1920x1080

# Render animation frame at t=2.5 seconds
pngine shader.pngine --frame -t 2.5

# Create PNG without embedded bytecode
pngine shader.pngine --no-embed

# Check bytecode in a PNG file
pngine check output.png

# Extract bytecode for inspection
pngine extract output.png -o extracted.pngb
```

### Supported File Formats

| Extension | Description |
|-----------|-------------|
| `.pngine` | DSL source (macro-based syntax) |
| `.pbsf` | Legacy PBSF source (S-expressions) |
| `.pngb` | Compiled bytecode |
| `.png` | PNG with optional embedded bytecode |

## DSL Syntax

```wgsl
#wgsl shader {
  value="
    @vertex fn vertexMain(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
      var pos = array<vec2f, 3>(vec2f(0, 0.5), vec2f(-0.5, -0.5), vec2f(0.5, -0.5));
      return vec4f(pos[i], 0, 1);
    }

    @fragment fn fragMain() -> @location(0) vec4f {
      return vec4f(1, 0.5, 0, 1);
    }
  "
}

#renderPipeline mainPipeline {
  vertex={ module=$wgsl.shader entryPoint="vertexMain" }
  fragment={ module=$wgsl.shader entryPoint="fragMain" }
}

#renderPass mainPass {
  pipeline=$renderPipeline.mainPipeline
  draw=3
}

#frame main {
  perform=[$renderPass.mainPass]
}
```

## How It Works

1. **Compile**: DSL source is compiled to compact PNGB bytecode
2. **Embed**: Bytecode is DEFLATE-compressed and embedded in a PNG's `pNGb` chunk
3. **Load**: Browser extracts bytecode from PNG using JavaScript
4. **Execute**: WASM runtime interprets bytecode and issues WebGPU calls

```
.pngine source ──► PNGB bytecode ──► PNG with pNGb chunk
                                            │
                                            ▼
                              Browser: extract ──► WASM ──► WebGPU
```

## File Sizes

| Content | Size |
|---------|------|
| Simple triangle (1x1 + bytecode) | ~700 bytes |
| Rotating cube (1x1 + bytecode) | ~5.6 KB |
| 512x512 rendered frame | ~100 KB |

## Development

```bash
# Run all tests (386 tests)
zig build test --summary all

# Build CLI
zig build

# Build WASM for web
zig build web
```

See [CLAUDE.md](CLAUDE.md) for development guidelines and architecture details.

## Status

- [x] DSL compiler with macro-based syntax
- [x] PNGB bytecode format
- [x] PNG embedding with DEFLATE compression
- [x] PNG extraction
- [x] CLI with render/check/embed/extract commands
- [ ] Real GPU rendering (currently uses stub backend)
- [ ] Browser WASM runtime
- [ ] JavaScript loader

## License

MIT
