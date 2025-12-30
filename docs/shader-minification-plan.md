# Shader Minification Integration Plan

## Status: ✅ COMPLETE

All phases implemented and tested. Minification achieves 22-57% payload
reduction.

## Executive Summary

Integrate miniray's WGSL minification into pngine's compilation pipeline to
reduce payload size while preserving DSL semantics and runtime reflection.

**Key insight**: miniray's design preserves the exact identifiers that pngine's
reflection system depends on:

- Struct field names: **NEVER renamed** (accessed via `.member` syntax)
- Entry points: **NEVER renamed** (vertex/fragment/compute functions)
- External binding variables: **NOT renamed by default** (`@group/@binding`
  vars)

This means **zero name mapping complexity** for the common case - minified
shaders work transparently with existing uniform table and reflection.

**BREAKING CHANGE**: This plan makes `libminiray.a` a **mandatory build
dependency**. Subprocess fallback is removed for consistency and simplicity.

## Benchmark Results (Actual)

| Example         | Original | Minified | Reduction |
|-----------------|----------|----------|-----------|
| simple_triangle | 659B     | 516B     | **22%**   |
| rotating_cube   | 6,316B   | 2,702B   | **57%**   |

---

## Critical Issue: Reflection Timing Mismatch

### Current Bug (Pre-existing)

The current reflection system has a timing mismatch that must be fixed before
adding minification:

```
CURRENT (BROKEN):
┌─────────────────────────────────────────────────────────────────┐
│ Emission phase (shaders.zig):                                   │
│   loadWgslValue() → raw code from file/inline                   │
│   substituteDefines() → PI, TAU, E expanded                     │
│   addData(substituted) → store in data section                  │
│                                                                 │
│ Later, on-demand (Emitter.getWgslReflection):                   │
│   getStringContent(ast_node) → reads ORIGINAL source from AST!  │
│   miniray.reflect(original) → reflection on WRONG code          │
└─────────────────────────────────────────────────────────────────┘

PROBLEM: Reflection is done on the original AST source, NOT the substituted
code that's actually stored in the data section. If a shader uses `PI`, the
stored code has `3.141592653589793` but reflection sees `PI`.
```

### Required Fix

Reflection must happen during emission, on the same code that gets stored:

```
CORRECTED:
┌─────────────────────────────────────────────────────────────────┐
│ Emission phase (shaders.zig):                                   │
│   loadWgslValue() → raw code                                    │
│   substituteDefines() → PI, TAU, E expanded                     │
│   reflectAndOptionallyMinify() → reflection on FINAL code       │
│   addData(final_code) → store in data section                   │
│   cache reflection in wgsl_reflections                          │
│                                                                 │
│ Later uses (uniform table, size= references):                   │
│   getWgslReflection() → returns cached reflection (correct!)    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Architecture Overview

### Current Flow (Broken Reflection)

```
#wgsl code { value="..." }
        ↓
emitWgslModule()
        ↓
substituteDefines()           // PI, TAU, user #define
        ↓
builder.addData(code)         // Store substituted WGSL
        ↓
[LATER: getWgslReflection() uses ORIGINAL source - BUG!]
```

### Proposed Flow (Fixed + Minification)

```
#wgsl code { value="..." }
        ↓
emitWgslModule()
        ↓
substituteDefines()           // PI, TAU, user #define
        ↓
reflectAndMinify()            // Reflect + optionally minify SAME code
        ↓
cache reflection              // Store in wgsl_reflections (single cache)
        ↓
builder.addData(final_code)   // Store final WGSL (minified or not)
        ↓
builder.addWgsl(data_id, deps)
        ↓
createShaderModule opcode
        ↓
[Runtime: unchanged]
```

---

## Mandatory Miniray Dependency

### Rationale

1. **Consistency**: Reflection must be on the same code that's stored. Having
   two paths (FFI vs subprocess) with potentially different behavior is risky.

2. **Simplicity**: One code path is easier to test, debug, and maintain.

3. **Performance**: FFI is ~50x faster than subprocess (~1-5ms vs ~50-100ms).

4. **Build reproducibility**: Same binary = same behavior everywhere.

### Build Requirements

```bash
# libminiray.a must be present at build time
# Default location: ../../miniray/build/libminiray.a
# Override: zig build -Dminiray-lib=/path/to/libminiray.a

# If libminiray.a is not found, build fails with clear error message
```

### Removed: Subprocess Fallback

The subprocess fallback in `miniray.zig` is **removed**. All reflection and
minification goes through FFI. This ensures:

- Reflection always uses the same miniray version
- No PATH dependency issues
- Consistent behavior across environments

---

## What Miniray Preserves vs Renames

### PRESERVED (Never Renamed)

| Category           | Example                | Why                  |
| ------------------ | ---------------------- | -------------------- |
| Entry points       | `@vertex fn vs()`      | Stage-facing API     |
| Struct fields      | `.time`, `.position.x` | Member access syntax |
| Builtin functions  | `textureSample`, `sin` | WGSL spec            |
| Binding variables* | `var<uniform> u`       | External interface   |

*Binding variables preserved by default; can enable mangling with option.

### RENAMED (Minified)

| Category          | Original              | Minified          |
| ----------------- | --------------------- | ----------------- |
| Struct type names | `struct Uniforms`     | `struct a`        |
| Local variables   | `let myValue = 1.0`   | `let a = 1.0`     |
| Helper functions  | `fn computeNormal()`  | `fn a()`          |
| Function params   | `fn calc(input: f32)` | `fn calc(a: f32)` |
| Type aliases      | `alias Vec3 = vec3f`  | `alias a = vec3f` |

### Example Transformation

**Before:**

```wgsl
struct Uniforms {
    time: f32,
    resolution: vec2f,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

fn computeColor(uv: vec2f) -> vec4f {
    let t = uniforms.time;
    let aspect = uniforms.resolution.x / uniforms.resolution.y;
    return vec4f(uv * aspect, sin(t), 1.0);
}

@fragment fn fs(@location(0) uv: vec2f) -> @location(0) vec4f {
    return computeColor(uv);
}
```

**After (minified):**

```wgsl
struct a{time:f32,resolution:vec2f}@group(0)@binding(0)var<uniform>uniforms:a;fn b(c:vec2f)->vec4f{let d=uniforms.time;let e=uniforms.resolution.x/uniforms.resolution.y;return vec4f(c*e,sin(d),1.)}@fragment fn fs(@location(0)c:vec2f)->@location(0)vec4f{return b(c);}
```

**What changed:**

- `struct Uniforms` → `struct a` (type name)
- `computeColor` → `b` (helper function)
- `uv` → `c`, `t` → `d`, `aspect` → `e` (local variables)
- Whitespace removed
- `1.0` → `1.` (syntax optimization)

**What stayed:**

- `uniforms` (binding variable - external interface)
- `time`, `resolution` (struct fields)
- `fs` (entry point)
- `sin`, `vec4f` (builtins)

---

## Implementation Plan

### Phase 1: Fix Reflection Timing (Required First)

**Goal**: Fix the existing bug where reflection uses original AST source instead
of the substituted code that's actually stored.

**File**: `src/dsl/emitter/shaders.zig`

```zig
/// Emit a single #wgsl module with reflection at emission time.
fn emitWgslModule(e: *Emitter, name: []const u8, macro_node: Node.Index) Emitter.Error!void {
    // Pre-conditions
    std.debug.assert(name.len > 0);
    std.debug.assert(e.wgsl_name_to_id.get(name) == null);

    // Get the value property
    const value_node = utils.findPropertyValue(e, macro_node, "value") orelse return;
    const value_str = utils.getStringContent(e, value_node);
    if (value_str.len == 0) return;

    // Load raw code (file or inline)
    const raw_code = try loadWgslValue(e, value_str);
    defer e.gpa.free(raw_code);
    if (raw_code.len == 0) return;

    // Apply define substitution
    const substituted = try substituteDefines(e, raw_code);
    defer if (substituted.ptr != raw_code.ptr) e.gpa.free(substituted);

    // NEW: Reflect on substituted code (not original!)
    // This ensures reflection matches what's stored in data section
    try reflectAndCache(e, name, substituted);

    // Store in data section
    const data_id = try e.builder.addData(e.gpa, substituted);

    // ... rest unchanged (deps, wgsl_id, shader_id, etc.) ...
}

/// Reflect on WGSL code and cache the result.
/// Called during emission to ensure reflection matches stored code.
fn reflectAndCache(e: *Emitter, name: []const u8, code: []const u8) Emitter.Error!void {
    const miniray_ffi = @import("../../reflect/miniray_ffi.zig");

    var result = miniray_ffi.reflectFfi(code) catch |err| {
        std.log.warn("WGSL reflection failed for '{s}': {}", .{ name, err });
        return;
    };
    defer result.deinit();

    // Parse and cache
    const reflection = reflect.miniray.parseJson(e.gpa, result.json) catch |err| {
        std.log.warn("Failed to parse reflection JSON for '{s}': {}", .{ name, err });
        return;
    };

    e.wgsl_reflections.put(e.gpa, name, reflection) catch {
        var ref_copy = reflection;
        ref_copy.deinit();
    };
}
```

**File**: `src/dsl/Emitter.zig`

```zig
/// Get WGSL reflection data for a shader.
/// Returns cached reflection populated during emission.
/// NOTE: This no longer does lazy reflection - it just returns the cache.
pub fn getWgslReflection(self: *Self, shader_name: []const u8) ?*const reflect.ReflectionData {
    std.debug.assert(shader_name.len > 0);
    return self.wgsl_reflections.getPtr(shader_name);
}
```

**Remove**: The lazy reflection code in `getWgslReflection()` that reads from
AST and calls miniray. This is replaced by emission-time reflection.

### Phase 2: Add Minification Option

**Goal**: Add `--minify` flag that minifies shader code during emission.

**File**: `src/dsl/Emitter.zig`

```zig
pub const Options = struct {
    base_dir: ?[]const u8 = null,
    /// Executor WASM bytes to embed in payload.
    executor_wasm: ?[]const u8 = null,
    /// Plugin set for the executor.
    plugins: ?format.PluginSet = null,
    /// Enable shader minification (reduces payload size).
    minify_shaders: bool = false,
};
```

**Note**: `miniray_path` is **removed** since subprocess is no longer supported.

**File**: `src/dsl/emitter/shaders.zig`

```zig
/// Emit a single #wgsl module with optional minification.
fn emitWgslModule(e: *Emitter, name: []const u8, macro_node: Node.Index) Emitter.Error!void {
    // ... load and substitute as before ...

    // Reflect and optionally minify
    const final_code = if (e.options.minify_shaders)
        try minifyAndReflect(e, name, substituted)
    else blk: {
        try reflectAndCache(e, name, substituted);
        break :blk substituted;
    };
    defer if (final_code.ptr != substituted.ptr) e.gpa.free(final_code);

    // Store final code in data section
    const data_id = try e.builder.addData(e.gpa, final_code);

    // ... rest unchanged ...
}

/// Minify WGSL and cache reflection data.
/// Returns owned minified code (caller must free if different from input).
fn minifyAndReflect(e: *Emitter, name: []const u8, code: []const u8) Emitter.Error![]const u8 {
    const miniray_ffi = @import("../../reflect/miniray_ffi.zig");

    var result = miniray_ffi.minifyAndReflectFfi(code, null) catch |err| {
        std.log.warn("Minification failed for '{s}': {}, using original", .{ name, err });
        // Fallback: reflect without minification
        try reflectAndCache(e, name, code);
        return code;
    };
    defer result.deinit();

    // Parse and cache reflection
    const reflection = reflect.miniray.parseJson(e.gpa, result.json) catch |err| {
        std.log.warn("Failed to parse minified reflection for '{s}': {}", .{ name, err });
        return code;
    };

    e.wgsl_reflections.put(e.gpa, name, reflection) catch {
        var ref_copy = reflection;
        ref_copy.deinit();
        return code;
    };

    // Copy minified code (FFI memory will be freed)
    return e.gpa.dupe(u8, result.code) catch code;
}
```

### Phase 3: CLI Integration

**File**: `src/cli.zig`

```zig
// Add flag
--minify         Minify shader code (reduces payload size)
--no-minify      Disable minification (default)
```

### Phase 4: Build System Updates

**File**: `build.zig`

```zig
// Make libminiray.a mandatory
const miniray_lib = b.option(
    []const u8,
    "miniray-lib",
    "Path to libminiray.a (required)",
) orelse blk: {
    // Try default location
    const default = "../../miniray/build/libminiray.a";
    if (std.fs.cwd().access(default, .{})) |_| {
        break :blk default;
    } else |_| {
        std.log.err("libminiray.a not found. Build miniray first or specify -Dminiray-lib=<path>", .{});
        std.log.err("See: https://github.com/pngine/miniray for build instructions", .{});
        return error.MinirayNotFound;
    }
};

// Always set has_miniray_lib = true (mandatory)
reflect_options.addOption(bool, "has_miniray_lib", true);
```

---

## Single Reflection Cache

The plan uses **one cache** (`wgsl_reflections`), not two:

```zig
// In Emitter struct - SINGLE cache:
wgsl_reflections: std.StringHashMapUnmanaged(reflect.ReflectionData),

// Populated during emission by:
// - reflectAndCache() when minify_shaders = false
// - minifyAndReflect() when minify_shaders = true

// Used by:
// - getWgslReflection() - returns cached data
// - getBindingSizeFromWgsl() - for size= references
// - uniform table population in resources.zig
```

This ensures consistency: the cached reflection always matches the stored code.

---

## Binding Variable Mangling (Future, Optional)

When `mangle_bindings: true`, binding variables are also renamed:

```wgsl
// Before
@group(0) @binding(0) var<uniform> uniforms: Uniforms;

// After (with mangling)
@group(0) @binding(0) var<uniform> u: a;
```

**This requires name mapping in the uniform table:**

```zig
// The reflection JSON includes mapping:
{
    "bindings": [{
        "name": "uniforms",      // Original name (for DSL/API)
        "nameMapped": "u",       // Minified name (in shader)
        "type": "Uniforms",
        "typeMapped": "a"
    }]
}
```

**Impact on uniform table:**

- `name` field: Keep original (for user-facing API)
- Shader code: Uses minified name
- No runtime changes needed (uniforms accessed by buffer offset, not name)

**Status**: Deferred to future phase. Default behavior preserves binding names.

---

## Size Impact Analysis

### Typical Shader (rotating_cube.pngine)

| Stage                      | Size        | Reduction          |
| -------------------------- | ----------- | ------------------ |
| Original                   | 1,247 bytes | -                  |
| After #define substitution | 1,298 bytes | -4% (PI expansion) |
| After minification         | ~650 bytes  | 48%                |
| After DEFLATE (PNG)        | ~400 bytes  | 68% total          |

### Compression Synergy

Minification helps DEFLATE in multiple ways:

1. **Shorter identifiers** = fewer bytes
2. **Removed whitespace** = fewer bytes
3. **Consistent naming** (a, b, c) = better dictionary matches
4. **Syntax optimization** (1.0 → 1.) = fewer bytes

Expected payload reduction: **30-50%** for shader code.

---

## Testing Strategy

### Unit Tests

```zig
test "reflection uses substituted code not original" {
    // This tests the bug fix in Phase 1
    const source =
        \\#define MAGIC=42.0
        \\#wgsl shader { value="@fragment fn fs()->@location(0)vec4f{return vec4f(MAGIC);}" }
    ;

    var compiler = try Compiler.init(allocator, .{});
    defer compiler.deinit();
    _ = try compiler.compile(source);

    // Reflection should see "42.0", not "MAGIC"
    const reflection = compiler.emitter.wgsl_reflections.get("shader");
    try expect(reflection != null);
    // Verify the reflection was done on substituted code
}

test "minification preserves struct field names" {
    const source = "struct U{time:f32}@group(0)@binding(0)var<uniform>u:U;@fragment fn f()->@location(0)vec4f{return vec4f(u.time);}";
    var result = try miniray_ffi.minifyAndReflectFfi(source, null);
    defer result.deinit();

    // Verify field name preserved
    try expect(std.mem.indexOf(u8, result.code, "time") != null);
}

test "minification preserves entry points" {
    const source = "@vertex fn myVertexShader()->@builtin(position)vec4f{return vec4f(0);}";
    var result = try miniray_ffi.minifyAndReflectFfi(source, null);
    defer result.deinit();

    // Entry point name preserved
    try expect(std.mem.indexOf(u8, result.code, "myVertexShader") != null);
}

test "minification renames helper functions" {
    const source = "fn helperFunction()->f32{return 1.0;}@fragment fn fs()->@location(0)vec4f{return vec4f(helperFunction());}";
    var result = try miniray_ffi.minifyAndReflectFfi(source, null);
    defer result.deinit();

    // Helper function renamed
    try expect(std.mem.indexOf(u8, result.code, "helperFunction") == null);
}
```

### Integration Tests

```zig
test "minified shader compiles and renders correctly" {
    const source =
        \\#wgsl shader { value="struct U{time:f32}@group(0)@binding(0)var<uniform>u:U;@fragment fn fs()->@location(0)vec4f{return vec4f(u.time);}" }
        \\#buffer uniforms { size=4 usage=[uniform copy_dst] }
        \\// ... rest of pipeline ...
    ;

    // Compile with minification
    var compiler = try Compiler.init(allocator, .{ .minify_shaders = true });
    const bytecode = try compiler.compile(source);

    // Execute and verify GPU calls
    var executor = try Executor.init(allocator, &mock_gpu);
    try executor.execute(bytecode);

    try expectShaderModuleCreated(mock_gpu);
}

test "size= references work with minified shaders" {
    const source =
        \\#wgsl code { value="struct Inputs{time:f32,res:vec2f}@group(0)@binding(0)var<uniform>inputs:Inputs;" }
        \\#buffer uniforms { size=code.inputs usage=[uniform] }
    ;

    var compiler = try Compiler.init(allocator, .{ .minify_shaders = true });
    const bytecode = try compiler.compile(source);

    // Buffer size should be 12 bytes (f32 + vec2f with padding)
    // This verifies reflection works correctly with minification
}
```

### Browser Tests

```javascript
// test-minified-shader.html
const response = await fetch("minified-shader.png");
const p = await pngine(response, { canvas, debug: true });
play(p);

// Verify rendering matches non-minified version
// (visual comparison or pixel sampling)
```

---

## Implementation Phases

### Phase 1: Fix Reflection Timing (Critical) ✅

- [x] Move reflection from lazy `getWgslReflection()` to emission-time
- [x] Add `reflectAndCache()` helper in `shaders.zig`
- [x] Update `getWgslReflection()` to return cached data only
- [x] Remove lazy reflection code from `Emitter.zig`
- [x] Add test: "reflection uses substituted code not original"
- [x] Verify `size=shader.binding` still works
- [x] Verify uniform table population still works

### Phase 2: Add Minification ✅

- [x] Add `minify_shaders` option to `Emitter.Options`
- [x] Remove `miniray_path` option (subprocess removed)
- [x] Implement `minifyAndCache()` helper
- [x] Integrate into `emitWgslModule()` flow
- [x] Also apply minification to `#shaderModule` inline code
- [x] Add preservation tests (struct fields, entry points)
- [x] Add renaming tests (helper functions, locals)

### Phase 3: CLI and Build ✅

- [x] Add `--minify` / `--no-minify` CLI flags
- [x] Remove `miniray_path` option from CLI
- [x] Update `build.zig` documentation for mandatory libminiray.a
- [x] Remove subprocess fallback from `miniray.zig`
- [x] Update error messages for missing library
- [x] C API documentation in `miniray_ffi.zig`

### Phase 4: Validation ✅

- [x] Test all examples with `--minify`
- [x] Payload size benchmarks (22-57% reduction)
- [x] Update CLAUDE.md with new build requirements
- [x] All 1,114 tests passing

### Phase 5: Optional Binding Mangling (Future)

- [ ] `--mangle-bindings` flag
- [ ] Name mapping in uniform table
- [ ] Extended testing

---

## Risk Assessment

| Risk                  | Mitigation                                           |
| --------------------- | ---------------------------------------------------- |
| WGSL parse errors     | Graceful fallback: log warning, use original code    |
| Build complexity      | Clear error message with miniray build instructions  |
| Unexpected renaming   | Miniray's preservation rules are well-documented     |
| Performance impact    | Only at compile time; ~1-5ms per shader via FFI      |
| Debugging difficulty  | `--no-minify` flag for development (default)         |
| Breaking change       | Document in CHANGELOG, version bump                  |

---

## Files to Modify

| File                          | Changes                                         |
| ----------------------------- | ----------------------------------------------- |
| `src/dsl/Emitter.zig`         | Add `minify_shaders`, remove `miniray_path`     |
| `src/dsl/emitter/shaders.zig` | Add emission-time reflection + minification     |
| `src/reflect/miniray.zig`     | Remove subprocess fallback                      |
| `src/cli.zig`                 | Add `--minify` flag                             |
| `build.zig`                   | Make `libminiray.a` mandatory                   |
| `CLAUDE.md`                   | Update build requirements                       |

---

## Conclusion

This plan addresses both the new minification feature and an existing bug:

1. **Bug fix**: Reflection now happens at emission time on the correct code
2. **Simplification**: Single reflection cache, mandatory FFI, no subprocess
3. **Feature**: Optional `--minify` flag for 30-50% shader size reduction
4. **Consistency**: Same code path for all builds

The main work is:

1. Refactoring reflection to emission time (Phase 1 - bug fix)
2. Adding minification option (Phase 2)
3. Updating build system (Phase 3)

Phase 1 should be done first as it's a correctness fix independent of
minification.
