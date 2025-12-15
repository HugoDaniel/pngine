# CLAUDE.md - PNGine Development Guide

## Project Overview

PNGine is a WebGPU bytecode engine that compiles high-level DSL into compact bytecode (PNGB) for embedding in PNGs and executing in browsers with a minimal WASM runtime.

**Goal**: Shader art that fits in a PNG file, executable in any browser.

## Quick Commands

```bash
# Run all tests (183 tests, 6 fuzz tests)
zig build test

# Run tests directly (more verbose output)
zig test src/main.zig

# Build CLI
zig build

# Run CLI
./zig-out/bin/pngine compile input.pbsf -o output.pngb
```

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
├── wasm.zig              # WASM entry points for browser
├── dsl/                  # New macro-based DSL compiler
│   ├── Token.zig         # Token definitions + macro keywords
│   ├── Lexer.zig         # Labeled switch state machine tokenizer
│   ├── Ast.zig           # Compact AST node definitions
│   ├── Parser.zig        # Iterative descent parser (no recursion)
│   ├── Analyzer.zig      # Semantic analysis + cycle detection
│   ├── Emitter.zig       # AST to PNGB bytecode
│   └── Compiler.zig      # High-level compile() interface
├── pbsf/                 # S-expression parser (older format)
│   ├── tokenizer.zig
│   └── parser.zig
├── bytecode/             # PNGB binary format
│   ├── format.zig        # Header + serialization
│   ├── opcodes.zig       # Opcode definitions + varint encoding
│   ├── string_table.zig  # Interned strings
│   ├── data_section.zig  # Shader code + vertex data
│   ├── emitter.zig       # Low-level bytecode emission
│   └── assembler.zig     # PBSF AST to PNGB
├── executor/             # Bytecode interpreter
│   ├── dispatcher.zig    # Opcode dispatch loop
│   ├── mock_gpu.zig      # Test backend (records calls)
│   └── wasm_gpu.zig      # Browser backend (WebGPU via JS)
└── fixtures/             # Test fixtures
    └── simple_triangle.zig
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
}

#computePass <name> {
  pipeline=$computePipeline.name
  dispatch=[x y z]
}

#frame <name> {
  perform=[$renderPass.pass1 $computePass.pass2]
}

#define <NAME>=<value>
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
zig test src/main.zig --test-filter "Parser: fuzz"

# Run with specific seed (for fuzz reproducibility)
zig test src/main.zig --seed 12345

# Verbose output
zig test src/main.zig 2>&1 | less
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

## Future Work (from plan)

1. **PNG Embedding** - `pNGb` ancillary chunk for PNGB data
2. **WASM Optimization** - Target ~15KB runtime (no std.fmt, static alloc)
3. **JS Loader** - Extract from PNG, init WebGPU, execute frames

## Related Files

- `/Users/hugo/.claude/plans/wondrous-puzzling-thacker.md` - Detailed implementation plan
- `/Users/hugo/Development/specs-llm/mastery/zig/` - Zig coding guidelines
