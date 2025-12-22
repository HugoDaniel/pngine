# PNGine

WebGPU bytecode engine - shader art that fits in a PNG file.

PNGine compiles a high-level DSL into compact bytecode (PNGB) that can be embedded in PNG files and executed in any WebGPU-capable browser.

## Installation

```bash
npm install pngine
```

## Quick Start

### Browser

```javascript
import { initPNGine } from 'pngine';

const canvas = document.getElementById('canvas');
const pngine = await initPNGine(canvas);

// Load and run shader from PNG
await pngine.loadFromUrl('shader.png');
pngine.startAnimation();
```

### CLI

```bash
# Compile source to bytecode
npx pngine compile shader.pngine -o output.pngb

# Create PNG with embedded bytecode
npx pngine shader.pngine -o output.png

# Render a frame
npx pngine shader.pngine --frame -s 1920x1080 -o render.png

# Extract bytecode from PNG
npx pngine extract shader.png -o extracted.pngb
```

## API

### Initialization

```javascript
import { initPNGine, initFromUrl, initFromPng } from 'pngine';

// Basic initialization
const pngine = await initPNGine(canvas);

// Initialize and load from URL (auto-detects format)
const pngine = await initFromUrl(canvas, 'shader.png');

// Initialize with options
const pngine = await initPNGine(canvas, {
  wasmUrl: '/path/to/pngine.wasm'
});
```

### Loading Modules

```javascript
// From URL (auto-detects PNG, ZIP, or PNGB)
await pngine.loadFromUrl('shader.png');

// From bytecode
const bytecode = await fetch('shader.pngb').then(r => r.arrayBuffer());
await pngine.loadModule(new Uint8Array(bytecode));

// From raw data
await pngine.loadFromData(arrayBuffer);
```

### Execution

```javascript
// Execute all frames
await pngine.executeAll();

// Execute specific frame
await pngine.executeFrameByName('main');

// Render at specific time
await pngine.renderFrame(2.5); // t = 2.5 seconds
```

### Animation

```javascript
// Start animation loop
pngine.startAnimation();

// Stop animation
pngine.stopAnimation();

// Select specific frame for animation
pngine.setFrame('sceneA');

// Listen for time updates (for UI sliders)
pngine.onTimeUpdate = (time) => {
  slider.value = time;
};
```

### Compilation

```javascript
// Compile source to bytecode
const source = `
  #shaderModule main {
    code="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0, 0, 0, 1); }"
  }
`;
const bytecode = await pngine.compile(source);
```

### Cleanup

```javascript
// Free current module
await pngine.freeModule();

// Terminate worker and release all resources
pngine.terminate();
```

## CLI Reference

```
pngine <command> [options] [file]

Commands:
  compile <input>      Compile .pngine source to bytecode
  embed <png> <pngb>   Embed bytecode into PNG image
  extract <png>        Extract bytecode from PNG
  check <file>         Validate bytecode or source
  render <input>       Render frame (alias for compile with --frame)

Options:
  -o, --output <path>  Output file path
  -f, --frame          Render actual frame via GPU
  -s, --size <WxH>     Output dimensions (default: 512x512)
  -t, --time <sec>     Time value for animation (default: 0.0)
  -e, --embed          Embed bytecode in PNG (default: on)
  --no-embed           Don't embed bytecode
  -h, --help           Show help
  -v, --version        Show version
```

## Supported Platforms

### Browser
- Any browser with WebGPU support (Chrome 113+, Edge 113+, Firefox 121+)
- Requires OffscreenCanvas support

### CLI (Native Binaries)
- macOS ARM64 (Apple Silicon)
- macOS x64 (Intel)
- Linux x64
- Linux ARM64
- Windows x64
- Windows ARM64

## DSL Syntax

```
#shaderModule name {
  code="WGSL shader code..."
}

#buffer name {
  size=1024
  usage=[VERTEX STORAGE]
}

#renderPipeline name {
  vertex={ module=shaderName entryPoint="vs" }
  fragment={ module=shaderName entryPoint="fs" }
}

#renderPass name {
  pipeline=pipelineName
  draw=3
}

#frame name {
  perform=[passName]
}
```

See [documentation](https://pngine.dev/docs) for complete DSL reference.

## Debug Mode

Enable debug logging:

```javascript
// Via URL parameter
// https://example.com/?debug=true

// Via localStorage
localStorage.setItem('pngine_debug', 'true');

// Via API
pngine.setDebug(true);
```

## License

MIT
