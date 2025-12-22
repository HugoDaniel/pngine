# CLAUDE.md - PNGine Development Guide

## Project Overview

PNGine is a WebGPU bytecode engine that compiles high-level DSL into compact bytecode (PNGB) for embedding in PNGs and executing in browsers with a minimal WASM runtime.

**Goal**: Shader art that fits in a PNG file, executable in any browser.

## Environment

```bash
# Zig binary location (use this path for all zig commands)
ZIG=/Users/hugo/.zvm/bin/zig
```

## Quick Commands

```bash
# Run all tests (473 tests)
/Users/hugo/.zvm/bin/zig build test

# Run tests with summary
/Users/hugo/.zvm/bin/zig build test --summary all

# Build CLI
/Users/hugo/.zvm/bin/zig build

# Build WASM for web
/Users/hugo/.zvm/bin/zig build web

# Build npm package (cross-compile for all platforms)
/Users/hugo/.zvm/bin/zig build npm

# Run CLI - basic compilation
./zig-out/bin/pngine compile shader.pngine -o output.pngb

# Run CLI - create PNG with embedded bytecode (default: 1x1 transparent)
./zig-out/bin/pngine shader.pngine -o output.png

# Run CLI - render actual frame
./zig-out/bin/pngine shader.pngine -o output.png --frame --size 512x512
```

## CLI Reference

### Commands

```bash
# Compile source to bytecode
pngine compile <input.pngine> [-o output.pngb]

# Validate bytecode (works with .pngine, .pbsf, .pngb, or .png with embedded bytecode)
pngine check <input>

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
```

### Supported File Formats

| Extension | Description |
|-----------|-------------|
| `.pngine` | DSL source (macro-based syntax) |
| `.pbsf` | Legacy PBSF source (S-expressions) |
| `.pngb` | Compiled bytecode |
| `.png` | PNG with optional embedded bytecode |

## Architecture

```
Input Formats          Compiler/Assembler           Output
─────────────          ──────────────────           ──────
DSL (.pngine.wgsl) ──► dsl/Compiler.zig ─────────►
                                                    PNGB bytecode
PBSF (S-expr)      ──► bytecode/assembler.zig ───►

PNGB bytecode ──► executor/dispatcher.zig ──► GPU calls
```

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
npm/                      # NPM package source
├── pngine/               # Main package
│   ├── bin/pngine        # CLI wrapper
│   ├── dist/             # Bundled JS + TypeScript defs
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

Runtime-provided uniform data that can be used in `#queue` writeBuffer operations:

| Identifier | Size | Description |
|------------|------|-------------|
| `pngineInputs` | 16 bytes | time(f32), width(f32), height(f32), aspect(f32) |
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
4. **Explicitly-sized types** - Use `u32`, `i64`, not `usize` (except slice indexing)
5. **Static allocation** - No malloc after init in runtime
6. **Functions ≤ 70 lines** - Exception: state machines with labeled switch

### Lexer/Parser Patterns

- **Sentinel-terminated input**: `[:0]const u8` for safe EOF
- **Labeled switch**: `state: switch (State.start) { ... continue :state .next; }`
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
6. **Test Organization** - Tests extracted to subdirectories (~500 lines per file)
7. **WebWorker Runtime** - OffscreenCanvas + WebWorker architecture for GPU operations
8. **NPM Package** - esbuild-style distribution with native binaries for 6 platforms

## Web Runtime

The web runtime uses WebWorker + OffscreenCanvas for all GPU operations.

### Debug Mode

Enable debug logging via any of:

```javascript
// URL parameter
http://localhost:8000/?debug=true

// localStorage (persists across sessions)
localStorage.setItem('pngine_debug', 'true')

// Runtime API
pngine.setDebug(true)
```

Debug output uses `[PNGine]` prefix for main thread, `[Worker]` for worker thread.

### Animation API

```javascript
const pngine = await initPNGine(canvas);
await pngine.loadFromUrl('shader.png');

// Start/stop animation
pngine.startAnimation();
pngine.stopAnimation();

// Select specific frame for animation
pngine.setFrame('sceneA');  // Render only sceneA
pngine.setFrame(null);      // Render all frames

// Time update callback (for UI slider sync)
pngine.onTimeUpdate = (time) => {
    slider.value = time;
};

// Manual frame rendering
await pngine.renderFrame(2.5);  // Render at t=2.5s
```

## NPM Package

PNGine is distributed as an npm package with native CLI binaries (similar to esbuild).

### Package Structure

```
npm/
├── pngine/                      # Main package
│   ├── bin/pngine               # CLI wrapper (finds native binary)
│   ├── dist/
│   │   ├── browser.mjs          # Browser bundle with inline worker
│   │   ├── browser.js           # CJS wrapper for bundlers
│   │   ├── index.mjs            # Node.js ESM entry
│   │   ├── index.js             # Node.js CJS entry
│   │   └── index.d.ts           # TypeScript definitions
│   ├── wasm/pngine.wasm         # WASM runtime (57K)
│   ├── scripts/
│   │   ├── bundle.js            # JS bundler script
│   │   └── prepare-publish.sh   # Copy binaries for publishing
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
# Build all platform binaries (cross-compilation)
/Users/hugo/.zvm/bin/zig build npm

# Bundle JavaScript (creates dist/ files)
node npm/pngine/scripts/bundle.js

# Prepare for publishing (copies binaries from zig-out to npm/)
./npm/pngine/scripts/prepare-publish.sh
```

### Binary Sizes

| Platform | Size |
|----------|------|
| darwin-arm64 | 927K |
| darwin-x64 | 981K |
| linux-x64 | 6.8M |
| linux-arm64 | 7.0M |
| win32-x64 | 1.2M |
| win32-arm64 | 1.1M |
| WASM | 57K |

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
import { initPNGine } from 'pngine';

const canvas = document.getElementById('canvas');
const pngine = await initPNGine(canvas);
await pngine.loadFromUrl('shader.png');
pngine.startAnimation();
```

### Build System Integration

The `build.zig` npm step:
- Cross-compiles CLI for 6 platforms using `b.resolveTargetQuery()`
- Uses `has_embedded_wasm = false` for cross-compiled builds (WASM not available at cross-compile time)
- Outputs to `zig-out/npm/pngine-{platform}/bin/`

## Future Work

1. **Real GPU Rendering** - Integrate zgpu/Dawn for actual shader execution
2. **WASM Optimization** - Target ~15KB runtime (no std.fmt, static alloc)

## Related Files

- `/Users/hugo/.claude/plans/wondrous-puzzling-thacker.md` - Detailed implementation plan
- `/Users/hugo/Development/specs-llm/mastery/zig/` - Zig coding guidelines
