# PNGine NPM Package

WebGPU bytecode engine - shader art that fits in a PNG file.

## Package Structure

```
npm/pngine/
├── src/                  # Source files (authoritative)
│   ├── index.js          # Public API exports
│   ├── init.js           # Main thread initialization
│   ├── worker.js         # WebWorker entry point
│   ├── gpu.js            # CommandDispatcher (WebGPU command execution)
│   ├── anim.js           # Animation controls (play/pause/stop)
│   └── extract.js        # Bytecode extraction from PNG/ZIP/PNGB
├── dist/                 # Bundled output (generated)
│   ├── browser.mjs       # Browser bundle with inline worker
│   ├── index.js          # Node.js CJS entry (stubs)
│   ├── index.mjs         # Node.js ESM entry (stubs)
│   └── index.d.ts        # TypeScript definitions
├── bin/pngine            # CLI wrapper (finds native binary)
├── wasm/pngine.wasm      # WASM runtime for browser
├── scripts/bundle.js     # esbuild bundler script
└── package.json
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Main Thread                             │
│  ┌─────────┐    ┌─────────┐    ┌───────────┐               │
│  │ init.js │───►│ anim.js │───►│ extract.js│               │
│  └────┬────┘    └─────────┘    └───────────┘               │
│       │ postMessage                                         │
│       ▼                                                     │
├───────────────────────── Worker ────────────────────────────┤
│  ┌───────────┐    ┌────────┐    ┌──────────────┐           │
│  │ worker.js │───►│ gpu.js │───►│ pngine.wasm  │           │
│  └───────────┘    └───┬────┘    └──────────────┘           │
│                       │                                     │
│                       ▼                                     │
│                   WebGPU API                                │
└─────────────────────────────────────────────────────────────┘
```

**Data Flow:**
1. `init.js` fetches PNG, extracts bytecode via `extract.js`
2. Creates OffscreenCanvas, spawns Worker
3. Worker initializes WebGPU and WASM
4. `anim.js` sends draw commands via postMessage
5. Worker executes WASM `renderFrame()` which returns command buffer
6. `gpu.js` CommandDispatcher executes GPU commands

## Public API

```javascript
// Browser usage
import { pngine, play, pause, stop, draw, destroy } from 'pngine';

// Initialize from PNG with embedded bytecode
const p = await pngine('shader.png', {
  canvas: document.getElementById('canvas'),
  debug: true,           // Enable console logging
  wasmUrl: 'pngine.wasm' // Optional: custom WASM path
});

// Animation control
play(p);                 // Start animation loop
pause(p);                // Pause (keeps time)
stop(p);                 // Stop and reset time to 0
draw(p, { time: 2.5 });  // Manual render at specific time
destroy(p);              // Cleanup resources

// Properties (read-only)
p.width;                 // Canvas width
p.height;                // Canvas height
p.frameCount;            // Number of frames in bytecode
p.isPlaying;             // Animation state
p.time;                  // Current time in seconds
```

## Source Files

### index.js (Public API)
```javascript
export { pngine, destroy } from "./init.js";
export { draw, play, pause, stop, seek, setFrame } from "./anim.js";
export { extractBytecode, detectFormat, isPng, isZip, isPngb } from "./extract.js";
```

### init.js (Main Thread)
- `pngine(source, options)` - Initialize from URL, selector, or data
- `destroy(p)` - Terminate worker and cleanup
- Handles: URL fetching, image element extraction, OffscreenCanvas transfer

### anim.js (Animation)
- `play(p)` - Start requestAnimationFrame loop
- `pause(p)` - Stop loop, preserve time
- `stop(p)` - Stop loop, reset time to 0
- `draw(p, opts)` - Single frame render
- `seek(p, time)` - Jump to time
- `setFrame(p, name)` - Select named frame

### extract.js (Bytecode Extraction)
- `extractBytecode(data)` - Extract from PNG/ZIP/PNGB
- `detectFormat(data)` - Returns 'png' | 'zip' | 'pngb' | null
- `isPng(data)`, `isZip(data)`, `isPngb(data)` - Format detection

### worker.js (Worker Entry)
- Receives messages: init, draw, load, destroy
- Initializes WebGPU device and context
- Loads WASM module
- Calls `wasm.renderFrame()` and executes command buffer

### gpu.js (Command Dispatcher)
- `CommandDispatcher` class - Executes binary command buffer from WASM
- Manages GPU resources: buffers, textures, pipelines, bind groups
- Parses pipeline descriptors from JSON in command buffer
- ~1200 lines due to WebGPU API complexity

## Command Buffer Protocol

WASM generates a binary command buffer, JS executes it:

```
┌──────────────────────────────────────┐
│ Command Buffer (from WASM memory)    │
├──────────────────────────────────────┤
│ [u8 opcode] [varint args...]         │
│ [u8 opcode] [varint args...]         │
│ ...                                  │
│ [0x00 END]                           │
└──────────────────────────────────────┘
```

Opcodes: CreateBuffer, CreateTexture, CreatePipeline, BeginRenderPass, Draw, etc.

## Build Commands

```bash
# Bundle for production (minified, drops console.log)
node scripts/bundle.js

# Bundle for debug (source maps, keeps console.log)
node scripts/bundle.js --debug

# Build WASM (from project root)
zig build web
```

## Bundle Sizes

| File | Size | Gzipped |
|------|------|---------|
| browser.mjs | 27.6 KB | 8.2 KB |
| index.js | 1.2 KB | - |
| pngine.wasm | 57 KB | - |

## CLI Usage

```bash
# Install
npm install pngine

# Compile .pngine to bytecode
npx pngine compile shader.pngine -o output.pngb

# Create PNG with embedded bytecode
npx pngine shader.pngine -o output.png

# Render frame via GPU
npx pngine shader.pngine --frame -s 512x512 -o preview.png
```

## Platform Binaries

The CLI uses native binaries distributed as optional dependencies:

| Package | Platform |
|---------|----------|
| @pngine/darwin-arm64 | macOS Apple Silicon |
| @pngine/darwin-x64 | macOS Intel |
| @pngine/linux-x64 | Linux x64 |
| @pngine/linux-arm64 | Linux ARM64 |
| @pngine/win32-x64 | Windows x64 |
| @pngine/win32-arm64 | Windows ARM64 |

## Key Implementation Details

1. **OffscreenCanvas + Worker**: All GPU operations happen in worker thread
2. **Command Buffer**: WASM generates binary commands, JS executes (no JS↔WASM per-call overhead)
3. **Inline Worker**: Browser bundle embeds worker as blob URL (no separate file needed)
4. **PNGB Format**: Compact bytecode with string table and data section
5. **pNGb Chunk**: Bytecode embedded in PNG ancillary chunk (invisible to image viewers)

## Internal State

The `pngine()` function returns a POJO with internal state in `p._`:

```javascript
{
  canvas,        // Original canvas element
  worker,        // Worker instance
  width,         // Canvas width
  height,        // Canvas height
  frameCount,    // Frames in bytecode
  playing,       // Animation state
  time,          // Current time
  startTime,     // Animation start timestamp
  animationId,   // requestAnimationFrame ID
  debug,         // Debug mode flag
  log,           // Logger function
}
```

## Worker Protocol

Messages between main thread and worker:

```javascript
// Main → Worker
{ type: 'init', canvas, bytecode, wasmUrl, debug }
{ type: 'draw', time, frame }
{ type: 'load', bytecode }
{ type: 'destroy' }

// Worker → Main
{ type: 'ready', width, height, frameCount }
{ type: 'error', message }
```

## Dependencies

- **Runtime**: None (browser built-ins only)
- **Build**: esbuild (bundling)
- **CLI**: Native Zig binaries (no Node.js runtime needed)

## License

MIT
