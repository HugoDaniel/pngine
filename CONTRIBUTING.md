# Contributing to PNGine

This document captures practical knowledge for developers working on PNGine,
including architectural insights, debugging strategies, and common pitfalls
learned from real development experience.

## Architecture Overview

### Data Flow

```
DSL Source (.pngine)
    │
    ▼
Compiler (Zig)
    ├── Parser → AST
    ├── Analyzer → Semantic validation
    └── Emitter → Bytecode (PNGB)
           │
           ▼
    ┌──────────────────────────────────────┐
    │ PNGB Bytecode (embedded in PNG)      │
    │ - Header (16 bytes)                  │
    │ - Opcodes (resource creation, draws) │
    │ - String Table (entry points)        │
    │ - Data Section (WGSL code, buffers)  │
    └──────────────────────────────────────┘
           │
           ▼
WASM Executor (wasm_entry.zig)
    ├── Parses bytecode opcodes
    ├── Reads data from Data Section
    └── Emits Command Buffer
           │
           ▼
JS Host (gpu.js)
    ├── Executes Command Buffer
    └── Calls WebGPU APIs
           │
           ▼
GPU (renders to canvas)
```

### Key Insight: Multiple ID Systems

PNGine uses several distinct ID systems that can be confusing:

| ID Type | Defined In | Purpose | Used By |
|---------|------------|---------|---------|
| `wgsl_id` | `wgsl_table.zig` | Index in WGSL module table | Compiler internal |
| `data_id` | `data_section.zig` | Index in bytecode data section | Bytecode/Executor |
| `shader_id` | Emitter | Logical shader resource ID | Pipelines |
| `buffer_id` | Emitter | Logical buffer resource ID | Bind groups |

**Critical**: The WASM executor (`wasm_entry.zig`) uses `data_id` to look up data
via `getDataSlice()`. When emitting bytecode, always pass `data_id`, not `wgsl_id`.

### Data Section Contents

The data section stores raw bytes referenced by `data_id`. Contents include:

1. **Expression strings** from `#data` blocks with `initEachElementWith`
2. **WGSL shader code** from `#wgsl` and `#shaderModule`
3. **Static float arrays** from `#data` blocks
4. **Descriptor data** for pipelines and bind groups

The order data is added determines the `data_id` assigned. Expression strings
from `#data` blocks are typically added first, pushing WGSL code to higher IDs.

## Common Pitfalls

### 1. Shader Gets Wrong Data

**Symptom**: `createShader(id=0, len=42, first50chars="cos((ELEMENT_ID...")` -
shader receives expression string instead of WGSL code.

**Cause**: Bytecode emitter passed `wgsl_id` but executor expected `data_id`.

**Fix Location**: `src/dsl/emitter/shaders.zig` - use `data_id.toInt()` in
`createShaderModule` calls.

**Test Case**: Any `.pngine` file with both `#data` blocks containing expressions
AND a `#shaderModule` with inline code.

### 2. Resource ID Mismatch

**Symptom**: Pipeline creation fails, "shader not found" errors.

**Cause**: Shader IDs weren't assigned when code was empty/invalid.

**Prevention**: The emitter skips empty shaders but must ensure IDs remain
consecutive. Test with empty `#wgsl` blocks mixed with valid ones.

### 3. Pool Buffer Confusion

**Symptom**: Ping-pong buffers use wrong buffer on alternating frames.

**Key Formula**: `actual_id = base_id + (frame_counter + offset) % pool_size`

**Testing**: Use `#buffer { pool=2 }` and verify alternation with debug logging.

## Debugging Strategies

### 1. Browser Console Logging

Enable debug mode to see GPU commands:

```javascript
// In browser console or URL parameter
localStorage.setItem('pngine_debug', 'true');
// or: http://localhost:5173/?debug=true
```

Look for prefixes:
- `[GPU]` - Command execution in gpu.js
- `[Worker]` - Worker thread events
- `[Executor]` - WASM executor logs

### 2. Chrome DevTools MCP (Recommended for WebGPU)

Headless browsers often fail to get WebGPU adapters. Use real Chrome:

```bash
# Launch Chrome with debugging
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chrome-debug-profile &

# Start dev server
npm run dev

# Use MCP tools to navigate and inspect
```

### 3. Bytecode Validation

```bash
# Check compiled bytecode
./zig-out/bin/pngine check output.png

# Output shows:
# - Resource counts (shaders, buffers, pipelines)
# - Entry point names
# - Buffer usage flags
# - Warnings about missing bind groups
```

### 4. Minimal Test Cases

Create minimal `.pngine` files to isolate issues:

```
# Minimal shader test (no #data)
#shaderModule code { code="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
#renderPipeline pipe { vertex={ module=code } }
#frame main { perform=[] }
```

```
# Test with #data before shader
#data testData { float32Array=["1.0" "2.0"] }
#shaderModule code { code="@fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
#frame main { perform=[] }
```

### 5. Adding Debug Output (Temporary)

For deep debugging, add prints in Zig:

```zig
std.debug.print("[DEBUG] shader_id={d}, data_id={d}, code_len={d}\n", .{
    shader_id,
    data_id.toInt(),
    code.len,
});
```

**Remember**: Remove debug prints before committing!

## Testing

### Test Hierarchy

```bash
# Fast: Individual module tests (~3s compile)
zig build test-types        # Core types
zig build test-bytecode     # Bytecode format
zig build test-executor     # Dispatcher + mock GPU

# Medium: DSL chain (~1min)
zig build test-dsl-complete # Full compilation tests

# Full: Everything including CLI (~5min)
zig build test
```

### Writing Regression Tests

For bugs involving bytecode generation, add tests to
`src/dsl/emitter/shader_id_test.zig` or similar:

```zig
test "ShaderID: shader with data blocks gets correct WGSL code" {
    const source: [:0]const u8 =
        \\#data testData { float32Array=["1.0"] }
        \\#shaderModule code { code="@vertex fn vs() ..." }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Execute and verify shader gets WGSL, not expression
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // ... verify shader code via mock GPU calls
}
```

### Browser Test Files

Create test HTML files in `demo/` directory:

```html
<!DOCTYPE html>
<html>
<head><title>Test Case Name</title></head>
<body>
  <canvas id="canvas" width="512" height="512"></canvas>
  <script type="module">
    import { pngine, play } from './pngine.js';
    const engine = await pngine('test_case.png', {
      canvas: document.getElementById('canvas'),
      debug: true
    });
    play(engine);
  </script>
</body>
</html>
```

## Code Organization

### Where to Add Features

| Feature Type | Location |
|--------------|----------|
| New DSL macro | `Token.zig` → `Parser.zig` → `Analyzer.zig` → `Emitter.zig` |
| New opcode | `opcodes.zig` → `emitter.zig` → `dispatcher.zig` → `mock_gpu.zig` |
| New GPU command | `command_buffer.zig` → `gpu.js` |
| New test | Appropriate `*_test.zig` file |

### File Size Guidelines

- Keep files under ~500 lines for LLM-friendliness
- Extract tests to `*/test.zig` subdirectories
- Split large emitters by resource type (shaders.zig, resources.zig, etc.)

## Zig Conventions

Follow the Zig mastery guidelines in CLAUDE.md:

1. **No recursion** - Use explicit stacks
2. **Bounded loops** - `for (0..MAX) |_| { } else unreachable`
3. **2+ assertions per function** - Pre/post conditions
4. **Explicit types** - `u32`, `i64`, not `usize` (except slice indexing)
5. **Functions <= 70 lines** - Exception: state machines

### Example Pattern

```zig
pub fn processShaders(e: *Emitter) Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const max_shaders = 256;
    for (0..max_shaders) |_| {
        const shader = e.getNextShader() orelse break;
        try e.emitShader(shader);
    } else unreachable; // Hit max without finishing

    // Post-condition
    std.debug.assert(e.shader_count <= max_shaders);
}
```

## Pull Request Checklist

- [ ] Tests pass: `zig build test-dsl-complete --summary all`
- [ ] No debug prints left in code
- [ ] Browser test verified (if UI-related)
- [ ] Commit message follows convention: `type(scope): description`
- [ ] New features have corresponding tests

## Common Commands

```bash
# Build
zig build                    # CLI binary
zig build web               # WASM + JS for browser

# Test
zig build test-standalone --summary all  # All standalone (parallel)
zig build test-dsl-complete             # DSL chain only

# Run
./zig-out/bin/pngine check output.png   # Validate bytecode
./zig-out/bin/pngine input.pngine -o output.png  # Compile

# Browser
npm run dev                 # Start Vite dev server
# Navigate to http://localhost:5173/
```

## Getting Help

- Check `CLAUDE.md` for detailed architecture docs
- Look at `docs/*.md` for implementation plans
- Run `pngine check` on bytecode to validate structure
- Enable debug mode in browser for detailed logging
