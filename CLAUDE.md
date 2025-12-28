# CLAUDE.md - PNGine Development Guide

## CRITICAL: Active Implementation Plan

**READ FIRST**: Before any implementation work, read the active plan:

- **`docs/cpu-wasm-data-initialization-plan.md`** - Buffer initialization with
  compile-time shapes and compute shader `#init`

This plan defines:

- Compile-time `#data` shape generators: `cube=`, `plane=`, `sphere=`
- Compute shader `#init` macro for GPU-generated procedural data
- Auto-sizing via shader reflection: `size=shader.varName`
- Frame `init=` support for one-time initialization
- **Phase 6 complete**: Fill opcodes removed, two approaches remain

**Zig Mastery Guidelines**: `/Users/hugo/Development/specs-llm/mastery/zig/`

- Always follow bounded loops, no recursion, 2+ assertions per function
- Functions ≤ 70 lines (exception: state machines with labeled switch)
- Explicitly-sized types (u32, i64, not usize except for slice indexing)
- Read TESTING_AND_FUZZING.md before writing tests

**If you discover of find anything relevant for other developers write it down
in CONTRIBUTING.md to help out further developments with compounded knowledge**

## Related Plans (Reference as Needed)

| Plan                                        | Purpose                                  | Status      |
| ------------------------------------------- | ---------------------------------------- | ----------- |
| `docs/cpu-wasm-data-initialization-plan.md` | **ACTIVE** - Buffer init + shapes        | In Progress |
| `docs/embedded-executor-plan.md`            | Embedded executor + plugins              | Reference   |
| `docs/llm-runtime-testing-plan.md`          | LLM-friendly validation via wasm3        | Complete    |
| `docs/multiplatform-command-buffer-plan.md` | Platform abstraction                     | Reference   |
| `docs/data-generation-plan.md`              | Compute shader data gen (superseded)     | Archived    |
| `docs/command-buffer-refactor-plan.md`      | JS bundle optimization                   | Reference   |
| `docs/remove-wasm-in-wasm-plan.md`          | **SUPERSEDED** - Do not use              | Archived    |

### Buffer Initialization (docs/cpu-wasm-data-initialization-plan.md)

Two approaches for buffer initialization:

**1. Compile-time shapes** (static meshes):
```
#data cubeVertexArray {
  cube={ format=[position4 color4 uv2] }
}
```

**2. Compute shader #init** (procedural data):
```
#init resetParticles {
  buffer=particles
  shader=initParticles
  params=[42]
}
```

Key features:

- **Built-in shapes**: `cube=`, `plane=`, `sphere=` with format specifiers
- **Auto-sizing**: `size=shader.varName` uses reflection
- **One-time init**: `#frame { init=[...] }` runs before first frame
- **GPU-native**: Compute shaders for procedural data

---

## Project Overview

PNGine is a WebGPU bytecode engine that compiles high-level DSL into compact
bytecode (PNGB) for embedding in PNGs and executing in browsers with a minimal
WASM runtime.

**Goal**: Shader art that fits in a PNG file, executable in any browser AND any
platform (iOS, Android, native) via embedded WASM executor.

## Environment

```bash
# Zig binary location (use this path for all zig commands)
ZIG=/Users/hugo/.zvm/bin/zig
```

## Quick Commands

```bash
# Standalone tests (1,114 tests, parallel compilation)
/Users/hugo/.zvm/bin/zig build test-standalone --summary all

# Fast filtered tests
/Users/hugo/.zvm/bin/zig test src/main.zig --test-filter "Parser"

# Full test suite including CLI (~5 min)
/Users/hugo/.zvm/bin/zig build test

# Run tests with summary
/Users/hugo/.zvm/bin/zig build test --summary all

# Build CLI
/Users/hugo/.zvm/bin/zig build

# Build WASM + JS for demo (outputs to zig-out/demo/)
/Users/hugo/.zvm/bin/zig build web

# Build minified production JS bundle (requires npm install)
/Users/hugo/.zvm/bin/zig build web-bundle

# Build npm package (cross-compile for all platforms)
/Users/hugo/.zvm/bin/zig build npm

# Run CLI - basic compilation
./zig-out/bin/pngine compile shader.pngine -o output.pngb

# Run CLI - create PNG with embedded bytecode (default: 1x1 transparent)
./zig-out/bin/pngine shader.pngine -o output.png

# Run CLI - render actual frame
./zig-out/bin/pngine shader.pngine -o output.png --frame --size 512x512
```

## Standalone Test Modules

The codebase is organized into standalone modules that compile and test in
parallel. This enables faster iteration when working on specific areas.

### Test Commands

```bash
# Run all standalone modules in parallel (~3s compile, varies for execution)
/Users/hugo/.zvm/bin/zig build test-standalone

# Run individual modules
/Users/hugo/.zvm/bin/zig build test-types        # 10 tests - Core type definitions
/Users/hugo/.zvm/bin/zig build test-pbsf         # 35 tests - S-expression parser
/Users/hugo/.zvm/bin/zig build test-png          # 91 tests - PNG encoding/embedding
/Users/hugo/.zvm/bin/zig build test-dsl-frontend # 75 tests - Token, Lexer, Ast, Parser
/Users/hugo/.zvm/bin/zig build test-dsl-backend  # 119 tests - Analyzer (semantic analysis)
/Users/hugo/.zvm/bin/zig build test-bytecode     # 147 tests - Format, opcodes, emitter
/Users/hugo/.zvm/bin/zig build test-reflect      # 9 tests - WGSL shader reflection
/Users/hugo/.zvm/bin/zig build test-executor     # 114 tests - Dispatcher, mock_gpu
/Users/hugo/.zvm/bin/zig build test-dsl-complete # 514 tests - Emitter + full DSL chain

# Full test suite (main lib + CLI, ~5min)
/Users/hugo/.zvm/bin/zig build test
```

### Module Dependency Graph

```
types (0 deps)
  ↓
bytecode (types)
  ↓
executor (bytecode)
  ↓
dsl-complete (types, bytecode, reflect, executor)
```

### Test Count Summary

| Module       | Tests | Description                    |
| ------------ | ----- | ------------------------------ |
| types        | 10    | Core type definitions          |
| pbsf         | 35    | S-expression parser            |
| png          | 91    | PNG encoding/embedding         |
| dsl-frontend | 75    | Token, Lexer, Ast, Parser      |
| dsl-backend  | 119   | Analyzer (semantic analysis)   |
| bytecode     | 147   | Format, opcodes, emitter, etc. |
| reflect      | 9     | WGSL shader reflection         |
| executor     | 114   | Dispatcher, mock_gpu, etc.     |
| dsl-complete | 514   | Emitter + full compilation     |
| **Total**    | 1,114 | Standalone tests               |

### When to Use Standalone Tests

- **Quick iteration**: `test-dsl-complete` for emitter work (~3min vs 5min full)
- **Focused development**: Test only the module you're changing
- **CI optimization**: Run standalone in parallel, then full suite
- **Debugging**: Isolate failures to specific modules

## Browser Testing (Playwright)

Automated browser testing with structured JSON output for LLM-friendly
iteration.

### Dev Server

```bash
# Start Vite dev server (port 5173)
npm run dev
```

### Console Capture Script

Captures all console output, errors, and optionally screenshots:

```bash
# Basic test - see console logs and errors
npm run browser http://localhost:5173/

# With screenshot (base64 PNG in output)
npm run browser http://localhost:5173/ -- --screenshot

# Wait for specific log message
npm run browser http://localhost:5173/ -- --wait-for "[GPU] Execute:"

# Custom wait time (default 2000ms)
npm run browser http://localhost:5173/ -- --wait 5000

# Show browser window (not headless)
npm run browser http://localhost:5173/ -- --no-headless
```

### Output Format

```json
{
  "success": true,
  "url": "http://localhost:5173/",
  "duration_ms": 2341,
  "webgpu_available": true,
  "logs": [
    { "time": 45, "level": "log", "prefix": "[GPU]", "message": "Execute: 12 commands" },
    { "time": 50, "level": "log", "prefix": "[Worker]", "message": "Ready" }
  ],
  "errors": [
    { "time": 30, "type": "console.error", "message": "Shader compilation failed..." }
  ],
  "warnings": [...],
  "summary": {
    "total_logs": 15,
    "gpu_commands": 12,
    "draw_calls": 1,
    "dispatch_calls": 0,
    "error_count": 0,
    "warning_count": 1
  },
  "screenshot": "base64..."
}
```

### Log Prefixes

| Prefix       | Source    | Meaning                  |
| ------------ | --------- | ------------------------ |
| `[GPU]`      | gpu.js    | WebGPU command execution |
| `[Worker]`   | worker.js | Worker thread events     |
| `[Executor]` | WASM      | Bytecode executor logs   |
| `[vite]`     | Vite      | Dev server HMR events    |
| `[Video]`    | gpu.js    | Video texture errors     |
| `[PNGine]`   | init.js   | Main thread events       |

### Playwright E2E Tests

Full Playwright test suite with WebGPU support:

```bash
npm test              # Run all E2E tests
npm run test:headed   # Run with visible browser
npm run test:debug    # Debug mode
```

Tests are in `tests/e2e/`. The Playwright config (`playwright.config.js`)
auto-starts Vite and enables WebGPU Chrome flags.

### Chrome DevTools MCP (Recommended for WebGPU)

**IMPORTANT**: Headless Playwright/Chromium often fails to get a WebGPU adapter
even with flags enabled. For reliable WebGPU testing, use Chrome with DevTools
MCP:

```bash
# 1. Launch Chrome with remote debugging (run in background)
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chrome-debug-profile &

# 2. Make sure dev server is running
npm run dev

# 3. Use MCP tools to interact with Chrome:
#    - mcp__chrome-devtools__navigate_page: Navigate to test URL
#    - mcp__chrome-devtools__list_console_messages: Check logs/errors
#    - mcp__chrome-devtools__take_screenshot: Visual verification
#    - mcp__chrome-devtools__list_pages: List open pages
```

**Test URLs:**

- `http://localhost:5173/` - Main demo
- `http://localhost:5173/test-embedded-executor.html` - Embedded executor test
- `http://localhost:5173/test-cmd-buffer-only.html` - Command buffer test (no
  GPU)

**Example MCP workflow:**

1. `mcp__chrome-devtools__navigate_page` to test page
2. Wait 2-3 seconds for WebGPU initialization
3. `mcp__chrome-devtools__list_console_messages` to see `[GPU]` and `[Worker]`
   logs
4. `mcp__chrome-devtools__take_screenshot` to verify rendering

**Why Chrome DevTools MCP?**

- Real Chrome = real WebGPU support (Metal on macOS, Vulkan on Linux)
- Console messages show full GPU command execution
- Screenshots verify actual rendering output
- No adapter/GPU availability issues like in headless mode

## CLI Reference

### Commands

```bash
# Compile source to bytecode
pngine compile <input.pngine> [-o output.pngb]

# Validate bytecode (works with .pngine, .pbsf, .pngb, or .png with embedded bytecode)
pngine check <input> [--verbose]

# Create PNG with embedded bytecode (default: 1x1 transparent pixel)
pngine <input.pngine> [-o output.png]
pngine render <input.pngine> [-o output.png]

# Render actual frame via GPU
pngine <input.pngine> --frame [-s WxH] [-t time] [-o output.png]

# Embed bytecode into existing PNG
pngine embed <image.png> <bytecode.pngb> [-o output.png]

# Extract bytecode from PNG
pngine extract <image.png> [-o output.pngb]
```

### Render Options

| Flag                   | Description                      | Default               |
| ---------------------- | -------------------------------- | --------------------- |
| `-o, --output <path>`  | Output PNG path                  | `<input>.png`         |
| `-f, --frame`          | Render actual frame via GPU      | Off (1x1 transparent) |
| `-s, --size <WxH>`     | Output dimensions (with --frame) | `512x512`             |
| `-t, --time <seconds>` | Time value for animation         | `0.0`                 |
| `-e, --embed`          | Embed bytecode in PNG            | On                    |
| `--no-embed`           | Don't embed bytecode             | Off                   |

### Check Options

| Flag           | Description                                      | Default |
| -------------- | ------------------------------------------------ | ------- |
| `-v, --verbose` | Print full GPU call trace (like browser debug)  | Off     |
| `-h, --help`   | Show help message                                | -       |

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

# Check with full GPU call trace (like browser debug mode)
pngine check shader.pngine --verbose
```

### Supported File Formats

| Extension | Description                         |
| --------- | ----------------------------------- |
| `.pngine` | DSL source (macro-based syntax)     |
| `.pbsf`   | Legacy PBSF source (S-expressions)  |
| `.pngb`   | Compiled bytecode                   |
| `.png`    | PNG with optional embedded bytecode |

## Architecture

```
Input Formats          Compiler/Assembler           Output
─────────────          ──────────────────           ──────
DSL (.pngine.wgsl) ──► dsl/Compiler.zig ─────────►
                                                    PNGB bytecode
PBSF (S-expr)      ──► bytecode/assembler.zig ───►

PNGB bytecode ──► executor/dispatcher.zig ──► GPU calls
```

### Runtime Pipeline (Detailed)

Understanding where code runs and what each component can do is critical for
making architectural decisions (like where to put mesh generators).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           BUILD TIME (once)                                  │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Compiler (Zig)                                                      │   │
│  │  - Parses DSL source (.pngine)                                       │   │
│  │  - Resolves references, validates semantics                          │   │
│  │  - CAN run arbitrary Zig code (mesh generators, etc.)                │   │
│  │  - Emits bytecode opcodes + data section                             │   │
│  │  - Complexity: unlimited (runs once on developer machine)            │   │
│  └────────────────────────────┬─────────────────────────────────────────┘   │
│                               │                                              │
│                               ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Payload (.pngb embedded in PNG)                                     │   │
│  │  - Declarative bytecode (WHAT to create, not HOW)                    │   │
│  │  - WGSL shader code as strings                                       │   │
│  │  - Static vertex data, textures, initial buffer values               │   │
│  │  - Resource descriptors (sizes, formats, bindings)                   │   │
│  │  - NO executable code (just data + opcodes)                          │   │
│  │  - Size constraint: should be <50KB total for practical use          │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ Distributed (PNG file)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          LOAD TIME (once per instance)                       │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Executor (WASM, 57KB)                                               │   │
│  │  - Parses bytecode header and opcodes                                │   │
│  │  - Dispatches commands to gpu.js via extern functions                │   │
│  │  - Manages frame loop and pass execution                             │   │
│  │  - CANNOT generate data (no mesh generators, no math)                │   │
│  │  - MUST stay tiny: goal is ~15KB                                     │   │
│  │  - Static allocation only (no malloc after init)                     │   │
│  └────────────────────────────┬─────────────────────────────────────────┘   │
│                               │                                              │
│                               │ extern "env" fn gpuCreateBuffer(...)        │
│                               ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  gpu.js (CommandDispatcher, ~1200 lines)                             │   │
│  │  - Implements actual WebGPU API calls                                │   │
│  │  - Creates GPUBuffer, GPUPipeline, GPUBindGroup, etc.                │   │
│  │  - CAN run arbitrary JavaScript                                      │   │
│  │  - CAN have helper functions (runtime mesh generators OK here)       │   │
│  │  - Handles platform adaptation (canvas formats, device limits)       │   │
│  │  - Already bundled with app, so +150 lines is marginal               │   │
│  └────────────────────────────┬─────────────────────────────────────────┘   │
│                               │                                              │
│                               │ device.createBuffer(), etc.                  │
│                               ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  GPU Resources                                                       │   │
│  │  - GPUBuffer, GPUTexture, GPUSampler                                 │   │
│  │  - GPURenderPipeline, GPUComputePipeline                             │   │
│  │  - GPUBindGroup, GPUBindGroupLayout                                  │   │
│  │  - Ready for rendering                                               │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ Resources ready
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          FRAME TIME (60fps)                                  │
│                                                                              │
│  Executor → gpu.js → GPU                                                     │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  GPU (WGSL shaders)                                                  │   │
│  │  - Vertex/Fragment shaders (every frame)                             │   │
│  │  - Compute shaders (simulation, particles, etc.)                     │   │
│  │  - Initialization compute (runOnce=true, first frame only)           │   │
│  │  - Massively parallel, extremely fast                                │   │
│  │  - CAN generate any data (noise, particles, transforms)              │   │
│  │  - WGSL code compresses well (~150 bytes for particle init)          │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component    | When   | Can Generate Data? | Size Constraint | Complexity OK? |
| ------------ | ------ | ------------------ | --------------- | -------------- |
| **Compiler** | Build  | Yes (Zig code)     | No limit        | Yes            |
| **Payload**  | Stored | No (just data)     | <50KB           | N/A            |
| **Executor** | Load   | No                 | ~15KB goal      | No             |
| **gpu.js**   | Load   | Yes (JS helpers)   | ~50KB OK        | Yes            |
| **GPU**      | Frame  | Yes (compute)      | N/A             | Yes (parallel) |

### Data Flow for Resource Creation

```
Opcode in payload:  CREATE_BUFFER { id=5, size=32768, usage=VERTEX|STORAGE }
        │
        ▼
Executor (WASM):    reads opcode, extracts params, calls extern fn
        │
        │  gpuCreateBuffer(5, 32768, 0xA0)
        ▼
gpu.js:             creates actual WebGPU resource
        │
        │  device.createBuffer({ size: 32768, usage: ... })
        ▼
GPU:                buffer exists, ready for use
```

### Where to Put Mesh Generators

Given the architecture, there are 3 viable places for mesh generators:

| Location           | Payload Size         | When Runs   | Adds Code To  |
| ------------------ | -------------------- | ----------- | ------------- |
| **Compiler (Zig)** | ~400B (vertex data)  | Build time  | Compiler only |
| **gpu.js (JS)**    | ~10B (opcode+params) | Load time   | JS bundle     |
| **GPU (WGSL)**     | ~150B (shader code)  | First frame | Payload       |

**Decision Framework:**

1. **Standard meshes (cube, sphere, plane)** → gpu.js or Compiler
   - gpu.js: smallest payload, runs at load time
   - Compiler: simple, no runtime code changes

2. **Large procedural data (particles, noise, heightmaps)** → GPU compute
   - WGSL compresses well
   - Runs in parallel
   - Uses existing compute infrastructure

3. **Small static data (<2KB)** → Compiler
   - Inline in payload
   - No runtime overhead

### Key Insight: Payload is Data, Not Code

The payload (.pngb) should be **declarative, not imperative**:

- **YES**: "create a buffer with these bytes" (data)
- **YES**: "run this WGSL shader" (GPU-executed code)
- **NO**: "generate cube vertices using this algorithm" (CPU-executed code)

The payload cannot contain executable code that runs on the CPU. It can only:

1. Contain static data (vertices, textures, parameters)
2. Reference WGSL code (executed by GPU, not payload)
3. Describe resources and their relationships

This means **compile-time generators cannot be "moved to the payload"** in a
literal sense. Instead, the choice is where the generator _runs_:

| Approach     | Generator Runs In | Payload Contains |
| ------------ | ----------------- | ---------------- |
| Compile-time | Compiler (Zig)    | Generated bytes  |
| Runtime JS   | gpu.js            | Opcode + params  |
| Runtime GPU  | GPU (WGSL)        | WGSL source      |

For the **runtime JS** approach, we would:

1. Add a new opcode like `FILL_CUBE_MESH { bufferId, size, format }`
2. Implement `_fillCubeMesh()` in gpu.js
3. Compiler emits the opcode instead of vertex bytes
4. Payload shrinks from ~400B to ~10B

This is viable because gpu.js already runs at load time and can have helper
functions.

### Directory Structure

```
src/
├── main.zig              # Module exports and test discovery
├── cli.zig               # Command-line interface
├── cli/
│   └── render.zig        # Render command implementation
├── wasm.zig              # WASM entry points for browser
├── dsl/                  # Macro-based DSL compiler
│   ├── Token.zig         # Token definitions + macro keywords
│   ├── Lexer.zig         # Labeled switch state machine tokenizer
│   ├── Ast.zig           # Compact AST node definitions
│   ├── Parser.zig        # Iterative descent parser (no recursion)
│   ├── parser/           # Parser tests (extracted for LLM-friendliness)
│   │   ├── test.zig      # Macro parsing, error handling, fuzz tests
│   │   └── expr_test.zig # Expression parsing, precedence tests
│   ├── Analyzer.zig      # Semantic analysis + cycle detection
│   ├── analyzer/         # Analyzer tests
│   │   ├── test.zig      # Reference resolution, symbol table tests
│   │   └── expr_test.zig # Expression evaluation, math constant tests
│   ├── Emitter.zig       # AST to PNGB bytecode
│   ├── emitter/          # Emitter tests
│   │   └── test.zig      # End-to-end compilation tests
│   └── Compiler.zig      # High-level compile() interface
├── pbsf/                 # S-expression parser (legacy format)
│   ├── tokenizer.zig
│   └── parser.zig
├── bytecode/             # PNGB binary format
│   ├── format.zig        # Header + serialization
│   ├── opcodes.zig       # Opcode definitions + varint encoding
│   ├── string_table.zig  # Interned strings
│   ├── data_section.zig  # Shader code + vertex data
│   ├── emitter.zig       # Low-level bytecode emission
│   └── assembler.zig     # PBSF AST to PNGB
├── png/                  # PNG encoding and bytecode embedding
│   ├── encoder.zig       # RGBA to PNG with DEFLATE compression
│   ├── embed.zig         # Embed bytecode in pNGb chunk
│   └── extract.zig       # Extract bytecode from pNGb chunk
├── gpu/                  # GPU backends
│   └── native_gpu.zig    # Native GPU backend (stub)
├── executor/             # Bytecode interpreter
│   ├── dispatcher.zig    # Opcode dispatch loop
│   ├── mock_gpu.zig      # Test backend (records calls)
│   └── wasm_gpu.zig      # Browser backend (WebGPU via JS)
├── fixtures/             # Test fixtures
│   └── simple_triangle.zig
examples/                 # Example .pngine files
├── simple_triangle.pngine
├── rotating_cube.pngine
└── boids.pngine          # Compute simulation with ping-pong buffers
demo/                     # Demo/test HTML files (not sources)
├── index.html            # Interactive demo page
├── test-*.html           # Development test pages
└── *.png                 # Demo assets (gitignored)
npm/                      # NPM package
├── pngine/               # Main package
│   ├── src/              # JS source files (authoritative)
│   │   ├── index.js      # Public API exports
│   │   ├── init.js       # Main thread initialization
│   │   ├── worker.js     # WebWorker entry point
│   │   ├── gpu.js        # CommandDispatcher (~1200 lines)
│   │   ├── anim.js       # Animation controls
│   │   └── extract.js    # Bytecode extraction
│   ├── bin/pngine        # CLI wrapper
│   ├── dist/             # Bundled JS + TypeScript defs
│   ├── scripts/          # Build scripts
│   │   └── bundle.js     # esbuild bundler
│   └── wasm/             # WASM runtime
└── pngine-{platform}/    # Platform-specific binaries (6 total)
```

## DSL Syntax Reference

```
#wgsl <name> {
  value="<shader code>"
  imports=[$wgsl.other]        // Optional: include other shaders
}

#buffer <name> {
  size=<bytes>
  usage=[vertex storage]       // Usage flags
  pool=2                       // Optional: ping-pong buffer pool size
}

#texture <name> { ... }
#sampler <name> { ... }

#bindGroup <name> {
  layout=$bindGroupLayout.name
  entries=[...]
}

#renderPipeline <name> {
  vertex={ module=$wgsl.shader entryPoint="vs" }
  fragment={ module=$wgsl.shader entryPoint="fs" }
}

#computePipeline <name> {
  compute={ module=$wgsl.shader entryPoint="main" }
}

#renderPass <name> {
  pipeline=$renderPipeline.name
  draw=<vertex_count>
  // or: drawIndexed=<index_count>
  vertexBuffers=[$buffer.pos $buffer.uv]  // Optional
  vertexBuffersPoolOffsets=[1 0]          // Pool offsets for ping-pong
  bindGroups=[$bindGroup.main]
  bindGroupsPoolOffsets=[0]
}

#computePass <name> {
  pipeline=$computePipeline.name
  dispatch=[x y z]
}

#frame <name> {
  perform=[renderPass computePass queue]
}

#queue <name> {
  writeBuffer={
    buffer=<buffer_name>
    bufferOffset=<offset>
    data=<data_source>           // Can be: data block, pngineInputs, sceneTimeInputs
  }
}

#define <NAME>=<value>
```

### Built-in Data Sources

Runtime-provided uniform data that can be used in `#queue` writeBuffer
operations:

| Identifier        | Size     | Description                                             |
| ----------------- | -------- | ------------------------------------------------------- |
| `pngineInputs`    | 16 bytes | time(f32), width(f32), height(f32), aspect(f32)         |
| `sceneTimeInputs` | 12 bytes | sceneTime(f32), sceneDuration(f32), normalizedTime(f32) |

**Example: Writing runtime inputs to a uniform buffer**

```
#buffer uniforms {
  size=16
  usage=[UNIFORM COPY_DST]
}

#queue writeInputs {
  writeBuffer={
    buffer=uniforms
    bufferOffset=0
    data=pngineInputs    // Built-in: runtime provides time/canvas data
  }
}

#frame main {
  perform=[writeInputs myRenderPass]  // Must include queue explicitly
}
```

**In WGSL (shader developer chooses binding):**

```wgsl
struct PngineInputs {
    time: f32,           // elapsed seconds since start
    canvasWidth: f32,    // canvas width in pixels
    canvasHeight: f32,   // canvas height in pixels
    aspect: f32,         // width / height
}

@group(0) @binding(0) var<uniform> pngine: PngineInputs;
```

### Ping-Pong Buffer Pattern

For compute simulations (e.g., boids, particles), use pool buffers with offsets:

```
#buffer particles {
  size=32768
  usage=[vertex storage]
  pool=2                // Creates particles_0, particles_1
}

#bindGroup sim {
  layout=auto
  entries=[
    { binding=0 buffer=$buffer.particles }  // Read from
    { binding=1 buffer=$buffer.particles }  // Write to
  ]
  bindGroupsPoolOffsets=[0 1]  // [0]: current, [1]: next
}

#computePass update {
  pipeline=$computePipeline.sim
  bindGroups=[$bindGroup.sim]
  bindGroupsPoolOffsets=[0]  // Alternates each frame
  dispatch=[64 1 1]
}
```

The runtime selects the actual buffer using:

```
actual_id = base_id + (frame_counter + offset) % pool_size
```

## PNGB Bytecode Format

```
┌─────────────────────────────────┐
│ Header (16 bytes)               │
│   magic: "PNGB"                 │
│   version: u16 (currently 1)   │
│   flags: u16                    │
│   string_table_offset: u32      │
│   data_section_offset: u32      │
├─────────────────────────────────┤
│ Bytecode (variable)             │
│   Frame definitions             │
│   Resource creation opcodes     │
├─────────────────────────────────┤
│ String Table                    │
│   Interned strings (entry pts)  │
├─────────────────────────────────┤
│ Data Section                    │
│   Shader code, vertex data      │
└─────────────────────────────────┘
```

## Coding Conventions

### Zig Mastery Principles (MUST FOLLOW)

1. **No recursion** - Use explicit stacks for tree traversal
2. **Bounded loops** - Always use `for (0..MAX_X) |_|` with `else unreachable`
3. **2+ assertions per function** - Pre-conditions and post-conditions
4. **Explicitly-sized types** - Use `u32`, `i64`, not `usize` (except slice
   indexing)
5. **Static allocation** - No malloc after init in runtime
6. **Functions ≤ 70 lines** - Exception: state machines with labeled switch

### Lexer/Parser Patterns

- **Sentinel-terminated input**: `[:0]const u8` for safe EOF
- **Labeled switch**:
  `state: switch (State.start) { ... continue :state .next; }`
- **StaticStringMap**: O(1) keyword lookup
- **Token = tag + location**: No string copies
- **Typed indices**: `enum(u32) { root = 0, _ }` not raw integers
- **Optional sentinel**: `none = std.math.maxInt(u32)`
- **Capacity heuristics**: 8:1 source:tokens, 2:1 tokens:nodes

### Testing Patterns

```zig
// Use testing.allocator (detects leaks)
const allocator = std.testing.allocator;

// Fuzz tests with std.testing.fuzz API
test "fuzz properties" {
    try std.testing.fuzz({}, fuzzFn, .{});
}

fn fuzzFn(_: void, input: []const u8) !void {
    // Filter invalid inputs
    for (input) |b| if (b == 0) return;
    // Test properties...
}

// OOM testing
var failing = std.testing.FailingAllocator.init(testing.allocator, .{
    .fail_index = 0,
});
```

### Documentation Patterns

```zig
//! Module-level docs with //! at top of file
//!
//! ## Design
//! - Key design decisions
//!
//! ## Invariants
//! - What must always be true

/// Function docs with ///
/// Complexity: O(n)
pub fn example() void {}

// Inline comments explain WHY not WHAT
```

## Common Tasks

### Adding a New Macro Type

1. Add token tag in `dsl/Token.zig` (`macro_keywords` StaticStringMap)
2. Add node tag in `dsl/Ast.zig` (Node.Tag enum)
3. Handle in `dsl/Parser.zig` (parseMacro switch)
4. Add symbol table in `dsl/Analyzer.zig` (SymbolTable struct)
5. Emit bytecode in `dsl/Emitter.zig`
6. Add tests

### Adding a New Opcode

1. Define in `bytecode/opcodes.zig` (Opcode enum)
2. Add emission in `bytecode/emitter.zig`
3. Handle dispatch in `executor/dispatcher.zig`
4. Add mock recording in `executor/mock_gpu.zig`
5. Add tests

### Debugging Test Failures

```bash
# Run specific test
/Users/hugo/.zvm/bin/zig test src/main.zig --test-filter "Parser: fuzz"

# Run with specific seed (for fuzz reproducibility)
/Users/hugo/.zvm/bin/zig test src/main.zig --seed 12345

# Verbose output
/Users/hugo/.zvm/bin/zig test src/main.zig 2>&1 | less
```

## Key Invariants

1. **Root node at index 0** - AST root is always `nodes[0]`
2. **Tokens reference source by index** - No string allocations during lexing
3. **Extra data for overflow** - Nodes > 8 bytes data use extra_data array
4. **Symbol tables per namespace** - Each resource type has separate hashmap
5. **Errors don't stop analysis** - Collected and reported at end
6. **PNGB is self-contained** - All data embedded, no external references

## Performance Notes

- Tokenizer: ~10M tokens/sec (labeled switch, no allocations in hot path)
- Parser: O(n) where n = source length
- Analyzer: O(nodes + references + imports²) worst case
- PNGB size: ~400 bytes for simple triangle (2.8x compression vs PBSF)

## Completed Features

1. **PNG Embedding** - `pNGb` ancillary chunk with DEFLATE-compressed bytecode
2. **PNG Extraction** - Extract bytecode from PNG files
3. **DEFLATE Compression** - Real zlib compression for IDAT chunks
4. **Render Command** - Default 1x1 transparent PNG, `--frame` for GPU rendering
5. **Pool Operations** - Ping-pong buffer patterns for compute simulations
6. **Test Organization** - Tests extracted to subdirectories (~500 lines per
   file)
7. **WebWorker Runtime** - OffscreenCanvas + WebWorker architecture for GPU
   operations
8. **NPM Package** - esbuild-style distribution with native binaries for 6
   platforms

## Web Runtime

The web runtime uses WebWorker + OffscreenCanvas for all GPU operations.

### Debug Mode

Enable debug logging via any of:

```javascript
// URL parameter
http:
//localhost:8000/?debug=true

// localStorage (persists across sessions)
localStorage.setItem("pngine_debug", "true");

// Runtime API
pngine.setDebug(true);
```

Debug output uses `[PNGine]` prefix for main thread, `[Worker]` for worker
thread.

### Animation API

```javascript
import { destroy, draw, pause, play, pngine, stop } from "pngine";

// Initialize from PNG with embedded bytecode
const p = await pngine("shader.png", {
  canvas: document.getElementById("canvas"),
  debug: true,
});

// Animation control (functional API)
play(p); // Start animation loop
pause(p); // Pause (keeps time)
stop(p); // Stop and reset to t=0
draw(p, { time: 2.5 }); // Manual render at specific time
destroy(p); // Cleanup resources

// Properties (read-only)
p.width; // Canvas width
p.height; // Canvas height
p.frameCount; // Number of frames
p.isPlaying; // Animation state
p.time; // Current time in seconds
```

## NPM Package

PNGine is distributed as an npm package with native CLI binaries (similar to
esbuild).

### Package Structure

```
npm/
├── pngine/                      # Main package
│   ├── src/                     # JS source files (authoritative)
│   │   ├── index.js             # Public API exports
│   │   ├── init.js              # Main thread initialization
│   │   ├── worker.js            # WebWorker entry point
│   │   ├── gpu.js               # CommandDispatcher
│   │   ├── anim.js              # Animation controls
│   │   └── extract.js           # Bytecode extraction
│   ├── bin/pngine               # CLI wrapper (finds native binary)
│   ├── dist/                    # Bundled output (generated)
│   │   ├── browser.mjs          # Browser bundle with inline worker
│   │   ├── index.mjs            # Node.js ESM entry (stubs)
│   │   ├── index.js             # Node.js CJS entry (stubs)
│   │   └── index.d.ts           # TypeScript definitions
│   ├── wasm/pngine.wasm         # WASM runtime (57K)
│   ├── scripts/bundle.js        # esbuild bundler script
│   ├── package.json
│   └── README.md
│
├── pngine-darwin-arm64/         # macOS Apple Silicon
├── pngine-darwin-x64/           # macOS Intel
├── pngine-linux-x64/            # Linux x64
├── pngine-linux-arm64/          # Linux ARM64
├── pngine-win32-x64/            # Windows x64
└── pngine-win32-arm64/          # Windows ARM64
    └── bin/pngine[.exe]         # Native binary
```

### Build Commands

```bash
# Build WASM + copy JS sources for development (outputs to zig-out/demo/)
/Users/hugo/.zvm/bin/zig build web

# Build minified production bundle (runs zig build web + esbuild)
/Users/hugo/.zvm/bin/zig build web-bundle

# Build all platform binaries (cross-compilation)
/Users/hugo/.zvm/bin/zig build npm

# Bundle JavaScript manually (creates dist/ files)
node npm/pngine/scripts/bundle.js          # Production (minified)
node npm/pngine/scripts/bundle.js --debug  # Debug (source maps, no minify)

# Prepare for publishing (copies binaries from zig-out to npm/)
./npm/pngine/scripts/prepare-publish.sh
```

### JavaScript Build System

The JS runtime uses esbuild for bundling with two build modes:

| Mode       | Command                              | Features                                    |
| ---------- | ------------------------------------ | ------------------------------------------- |
| Production | `node scripts/bundle.js`             | Minified, `DEBUG=false`, strips debug logs  |
| Debug      | `node scripts/bundle.js --debug`     | Source maps, `DEBUG=true`, preserves logs   |

**Bundle sizes** (production):
- `browser.mjs`: 23.7 KB (8.1 KB gzipped)
- `index.js`: 1.2 KB (Node.js stubs)

**Key optimization**: The `gpu.js` uses a closure pattern instead of classes, enabling better minification:
```javascript
// Closure pattern: private vars renamed by minifier
export function createCommandDispatcher(device, ctx) {
  let debug = false;  // Becomes single-letter var
  const setDebug = (v) => { debug = v; };
  return { setDebug, execute, destroy };
}
```

**DEBUG flag usage in gpu.js**:
```javascript
// Stripped in production (DEBUG=false)
if (DEBUG) console.log('[GPU] Execute:', commands.length, 'commands');
```

### Binary Sizes

| Platform     | Size |
| ------------ | ---- |
| darwin-arm64 | 927K |
| darwin-x64   | 981K |
| linux-x64    | 6.8M |
| linux-arm64  | 7.0M |
| win32-x64    | 1.2M |
| win32-arm64  | 1.1M |
| WASM         | 57K  |

### Publishing Workflow

```bash
# 1. Build everything
zig build npm
node npm/pngine/scripts/bundle.js
./npm/pngine/scripts/prepare-publish.sh

# 2. Publish platform packages first (order doesn't matter)
cd npm/pngine-darwin-arm64 && npm publish --access public
cd npm/pngine-darwin-x64 && npm publish --access public
cd npm/pngine-linux-x64 && npm publish --access public
cd npm/pngine-linux-arm64 && npm publish --access public
cd npm/pngine-win32-x64 && npm publish --access public
cd npm/pngine-win32-arm64 && npm publish --access public

# 3. Publish main package (after platform packages)
cd npm/pngine && npm publish
```

### Usage

```bash
# Install
npm install pngine

# CLI usage (uses native binary)
npx pngine compile shader.pngine -o output.pngb
npx pngine shader.pngine -o output.png --frame
```

```javascript
// Browser usage
import { play, pngine } from "pngine";

const canvas = document.getElementById("canvas");
const p = await pngine("shader.png", { canvas });
play(p);
```

### Build System Integration

The `build.zig` npm step:

- Cross-compiles CLI for 6 platforms using `b.resolveTargetQuery()`
- Uses `has_embedded_wasm = false` for cross-compiled builds (WASM not available
  at cross-compile time)
- Outputs to `zig-out/npm/pngine-{platform}/bin/`

## Current Work: Embedded Executor

**Active Plan**: `docs/embedded-executor-plan.md`

Implementation phases:

1. Payload format extension (v5 header with executor section)
2. Plugin infrastructure (detection in Analyzer, multi-variant builds)
3. Executor refactor (clean exports, conditional compilation)
4. Embedding integration (`--embed-executor` CLI flag)
5. Complete [wasm] plugin (JS and native nested WASM execution)
6. Browser loader refactor (minimal ~300 line loader)
7. Native viewers (iOS/Android/Desktop via wasm3)

## Related Files

**Plans (read in order of priority)**:

- `docs/embedded-executor-plan.md` - **ACTIVE** - Embedded executor + plugin
  architecture
- `docs/llm-runtime-testing-plan.md` - LLM runtime validation via wasm3
  (planned)
- `docs/multiplatform-command-buffer-plan.md` - Platform abstraction (reference)
- `docs/data-generation-plan.md` - Compute shader data generation (reference)

**Zig Guidelines**:

- `/Users/hugo/Development/specs-llm/mastery/zig/` - Zig coding conventions
  (MUST follow)

**Key Implementation Files**:

- `src/executor/command_buffer.zig` - Command buffer format (preserve)
- `src/dsl/emitter/wasm.zig` - WASM-in-WASM emitter (keep as [wasm] plugin)
- `src/bytecode/opcodes.zig` - Opcodes 0x30-0x31 for nested WASM (keep)
