# PNGine TODO

## Critical (Blocking Real Use)

### NativeGPU Backend
- [ ] Integrate zgpu/Dawn for actual GPU rendering
  - Current `src/gpu/native_gpu.zig` is a stub producing test gradient
  - Need to map resource IDs to actual GPU resources (buffers, textures, pipelines)
  - Implement pixel readback via staging buffer + texture copy
  - Handle headless rendering (no window/surface)

### PNG Encoder Compression
- [x] ~~Implement actual zlib deflate compression~~ **DONE**
  - Uses `std.compress.flate` with zlib container (level 6)
  - Solid color 256x256 compresses to <10% of raw size
  - 512x512 renders produce ~100KB files (was 1MB+)

---

## Important (Quality of Life)

### Render Command Enhancements
- [ ] Progress indicator for large renders
- [ ] Validate shader compilation before GPU init
- [ ] Better error messages with line numbers for shader errors
- [ ] Support `.pngb` input (skip compilation step)

### GPU Backend
- [ ] Implement BGRA pixel readback (current stub uses RGBA)
  - Real GPU textures are often BGRA; need `encodeBGRA()` path
- [ ] Surface/swapchain support for preview window mode
- [ ] Multiple render target support

### Build System
- [ ] Test zgpu dependency fetch and build on CI
- [ ] Cross-compilation support (Windows, Linux from macOS)
- [ ] Release build optimization flags

---

## Nice to Have (Future)

### Batch Rendering
- [ ] Render multiple frames for GIF/video export
  ```bash
  pngine render animation.pngine --frames 60 --fps 30 -o animation.gif
  ```
- [ ] Frame range selection: `--start 0 --end 5`

### Watch Mode
- [ ] Hot reload on source file change
  ```bash
  pngine render shader.pngine --watch
  ```
- [ ] Live preview window (requires surface support)

### Compute Shaders
- [ ] Render compute shader output to texture
- [ ] Support compute-only pipelines without render pass

### CLI Polish
- [ ] Quiet mode (`-q`) for scripting
- [ ] Verbose mode (`-v`) for debugging
- [ ] JSON output format for tooling integration
- [ ] Config file support (`.pnginerc`)

### PNG Features
- [ ] PNG metadata (author, description, timestamp)
- [ ] Interlaced PNG output for progressive loading
- [ ] 16-bit color depth option

### Performance
- [ ] Parallel compilation for multiple files
- [ ] Bytecode caching (skip recompile if source unchanged)
- [ ] Memory-mapped file I/O for large assets

### Documentation
- [ ] Man page generation
- [ ] Shell completion scripts (bash, zsh, fish)
- [ ] Example gallery with rendered outputs

---

## Known Issues

1. ~~**Large PNG files**: Uncompressed zlib produces ~1MB for 512x512~~ **FIXED** - Now uses DEFLATE compression
2. **zgpu not tested**: Lazy dependency added but never fetched/built
3. **No real rendering**: NativeGPU produces gradient, not actual shader output
4. **Time uniform unused**: `setTime()` called but stub ignores it

---

## Architecture Notes

### Current Flow
```
.pngine source
    │
    ▼
dsl/Compiler.zig ──► PNGB bytecode
    │
    ▼
NativeGPU.init(width, height)
    │
    ▼
Dispatcher.executeAll() ──► GPU calls (stub: gradient fill)
    │
    ▼
NativeGPU.readPixels() ──► RGBA bytes
    │
    ▼
png/encoder.encode() ──► PNG file (DEFLATE compressed)
    │
    ▼
[optional] png/embed.embed() ──► PNG with pNGb chunk
```

### Target Flow (with real GPU)
```
.pngine source
    │
    ▼
dsl/Compiler.zig ──► PNGB bytecode
    │
    ▼
zgpu.Device.init() ──► Dawn/WebGPU device
    │
    ▼
NativeGPU.init() ──► offscreen texture + resource maps
    │
    ▼
Dispatcher.executeAll() ──► real GPU commands
    │
    ▼
copyTextureToBuffer() + mapAsync() ──► BGRA bytes
    │
    ▼
png/encoder.encodeBGRA() ──► PNG file (compressed)
```

---

## References

- zgpu: https://github.com/zig-gamedev/zgpu
- Dawn: https://dawn.googlesource.com/dawn
- PNG spec: http://www.libpng.org/pub/png/spec/1.2/PNG-Contents.html
- zlib format: https://www.ietf.org/rfc/rfc1950.txt
