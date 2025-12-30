# Plan: Remove pNGr Chunk, Use Tailored Executor Only

> **Status**: ✅ Complete (2024-12-30)
> **Author**: Claude + Hugo
> **Date**: 2024-12-30
> **Version**: v0 (pre-release, breaking changes allowed)

---

## Summary

Remove the pNGr PNG chunk mechanism entirely. Embed tailored executor by default.
Self-contained PNGs that "just work" without external dependencies.

---

## Background

### Current State: Two Embedding Mechanisms

PNGine currently has two ways to embed the WASM executor:

| Mechanism        | Flag                            | Size            | JS Support          |
| ---------------- | ------------------------------- | --------------- | ------------------- |
| **pNGr chunk**   | `--embed-runtime` (default ON)  | ~57KB (full)    | **Not implemented** |
| **In payload**   | `--embed-executor` (default OFF)| ~15KB (tailored)| Fully working       |

### The Problem

1. **pNGr is half-implemented**: CLI embeds it by default, but JS ignores it
2. **Wasted bytes**: Every PNG has ~30KB of compressed WASM that browsers never use
3. **Redundant approaches**: Two ways to solve the same problem
4. **pNGr is inferior**: Full executor (~57KB) vs tailored (~15KB based on plugins)

---

## Solution

### Delete pNGr Completely

Remove all pNGr code. Embed tailored executor by default. Add `--no-executor`
flag for dev builds that need shared `pngine.wasm`.

### New CLI Modes

| Use Case         | Command                              | Result                                    |
| ---------------- | ------------------------------------ | ----------------------------------------- |
| **Default**      | `pngine shader.pngine`               | Self-contained (~17KB), no external deps  |
| **Development**  | `pngine shader.pngine --no-executor` | Small PNG (~2KB), needs `pngine.wasm`     |
| **Preview only** | `pngine shader.pngine --no-embed`    | Just image, no bytecode                   |

**Embed executor by default.** Self-contained PNGs that "just work" is the right UX.

---

## Implementation

### Files to Delete

1. **`src/png/runtime.zig`** - Delete entire file (~200 lines)

### Files to Modify

1. **`src/cli/render.zig`**
   - Remove `embed_runtime` field and `embedRuntimeData()` function
   - Remove `--embed-runtime` / `--no-runtime` flags
   - Change `embed_executor` default from `false` to `true`
   - Rename `--embed-executor` to `--no-executor` (inverted logic)
   - Update help text

2. **`src/png/main.zig`**
   - Remove `runtime` export

3. **`src/png/chunk.zig`**
   - Remove `pNGr` from `ChunkType` enum

4. **`src/png/extract.zig`** (if exists)
   - Remove any pNGr extraction code

### Tests to Delete/Update

- Delete any tests in `src/png/` that test pNGr embedding/extraction
- Update CLI tests that reference `--embed-runtime` or `--no-runtime`

### Documentation to Update

1. `CLAUDE.md` - Remove pNGr references, update CLI reference
2. `docs/embedded-executor-plan.md` - Mark pNGr removal as complete

---

## Why This is Better

### 1. Tailored Executors are Smaller

| Shader Type        | Plugins Needed                      | Size   |
| ------------------ | ----------------------------------- | ------ |
| Simple render      | core + render                       | ~12KB  |
| Compute simulation | core + compute                      | ~13KB  |
| Full demo          | core + render + compute + animation | ~18KB  |

vs pNGr which always embeds the full ~57KB executor.

### 2. Already Fully Implemented

The tailored executor path works end-to-end:
- CLI: `--embed-executor` builds variant, embeds in payload
- JS loader.js: `parsePayload()` extracts embedded executor
- JS worker.js: `createExecutor()` instantiates directly
- Tests: Integration tests verify the flow

pNGr would need ~50 lines of new JS code to even work.

### 3. Cleaner Architecture

One way to do self-contained = less confusion, less code, fewer bugs.

```
Before (confusing):
  --embed-runtime (default ON, but doesn't work in browser!)
  --embed-executor (works, but default OFF)

After (clear):
  (nothing) = self-contained, just works
  --no-executor = small dev build, needs pngine.wasm
```

---

## Success Criteria

1. **No pNGr code**: `runtime.zig` deleted, `pNGr` removed from ChunkType
2. **Self-contained by default**: `pngine shader.pngine` embeds tailored executor
3. **`--no-executor` flag**: Opt-out for dev builds that need shared `pngine.wasm`
4. **Tests pass**: All functionality preserved
5. **Docs updated**: No references to pNGr or `--embed-runtime`

---

## Appendix: Code to Remove

### src/png/runtime.zig (DELETE ENTIRE FILE)

```zig
// DELETE THIS FILE
//! Embed and extract WASM runtime from PNG files.
//! Creates a pNGr ancillary chunk...
```

### src/cli/render.zig (changes)

```zig
// REMOVE:
embed_runtime: bool,
.embed_runtime = true,
if (embed_runtime) { ... }
fn embedRuntimeData(...) { ... }
"--embed-runtime" / "--no-runtime" handling

// CHANGE:
embed_executor: bool = false,  // → true (default ON)
"--embed-executor"             // → "--no-executor" (inverted)
```

### src/png/chunk.zig

```zig
// REMOVE from ChunkType enum:
pNGr,
```

### Approximate Diff Size

- Lines removed: ~250 (runtime.zig + embed_runtime code)
- Lines modified: ~10 (default + flag rename)
- Net: **~-240 lines**
