# PNGine Examples

Every `.sjon` file here is a working program for the current compiler.
`scripts/validate-corpus.sh` validates all of them.

```bash
# Compile to bytecode
./zig-out/bin/pngine compile examples/simple_triangle.sjon -o out.pngb

# PNG with embedded bytecode + executor (self-contained)
./zig-out/bin/pngine examples/simple_triangle.sjon -o out.png

# Render an actual frame (needs a GPU build — default on macOS)
./zig-out/bin/pngine examples/teapot.sjon --frame -s 512x512 -o out.png

# Check one without building anything
./zig-out/bin/pngine validate examples/boids.sjon
```

Each file opens with a comment saying what it renders and which features it
exercises. Read that header first — it is more specific than this index.

## Top level

| Group | Files |
|-------|-------|
| **Basics** | `simple_triangle`, `simple_triangle_msaa`, `moving_triangle`, `rotating_cube`, `two_cubes`, `uniform_access`, `pipeline_layout`, `pipeline_constants`, `primitive_strip`, `test_viewport`, `test_define_wgsl`, `transparent_canvas`, `test_multi_draw` (several draws in one pass), `test_instanced_simple` / `test_instanced_builtin` (instanced draws with and without vertex buffers), `test_bind_offset` (a bind-group buffer slice) |
| **Fullscreen fragment** | `circle_avalanche`, `domino_cascade`, `tower_explosion`, `pngine_logo`, `pristine_grid` |
| **`(pass …)` sugar** | `pass_shader_art`, `pass_bloom`, `pass_postprocess`, `pass_compute_rainbow`, `pass_pointer` |
| **Compute / simulation** | `boids`, `boids_init_only`, `pngine_background`, `test_compute_dispatch`, `test_init_compute`, `test_storage_buffer`, `test_boids_render` (and the `boids_*` triangles below) |
| **Meshes** | `teapot` (Utah teapot), `dragon` (Stanford dragon, ~222 KB payload), `textured_rotating_cube`, `wasm_rotated_cube`, `normal_map`, `cubemap` |
| **Textures & samplers** | `texture_options`, `texture_view`, `sampler_options`, `image_blur`, `test_cube_view` (a `2d-array` storage view, then a cube view), `test_copy_buffer`, `test_copy_texture` |
| **Depth, stencil & MSAA** | `test_stencil`, `test_stencil_back`, `test_depth_clear` (depth/stencil clear values), `reversed_z` (reversed-Z depth, a webgpu-samples port), `alpha_to_coverage` (alpha-to-coverage vs blending in one 4x MSAA attachment) |
| **WASM data buffers** | `test_data_pass`, `test_wasm_data` (+ `test_data.wat` / `.wasm` sources) |
| **WebGPU sample ports** | `webgpu_*` — ports of the upstream [webgpu-samples](https://webgpu.github.io/webgpu-samples/) gallery, plus a few focused feature programs in the same style |

The `boids_*` family: `boids.sjon` is a compute simulation with ping-pong pool
buffers and an instanced draw; `boids_init_only` seeds a buffer with an
`(init …)` compute pass; the remaining five (`boids_minimal`, `boids_simple`,
`boids_array_only`, `boids_const_data`, `boids_define_only`) are single
hardcoded triangles that differ in one detail each (a fragment colour, an
unused define) — despite the names, none has a `(data …)` or a compute pass.
The three fullscreen-fragment programs named after physics demos
(`circle_avalanche`, `domino_cascade`, `tower_explosion`) are single-quad SDF
shaders, not simulations.

## Subdirectories

| Directory | What it is |
|-----------|-----------|
| `samples/` | A numbered series of small programs (`01_`–`29_`): gradient background, plasma, sprite rendering, lighting, skybox, game of life, fluid, wave simulation, … |
| `invalid/` | Programs that **must** fail `pngine validate` — one per rejected condition. |
| `assets/` | Shared binary assets (textures, `.wasm` data modules, video). |
| `vite-basic/` | Minimal Vite app consuming the npm runtime. |
| `vite-gallery/` | Vite app cycling through several compiled shaders. |
| `audio-demo/` | Browser demo of the audio/playback path. |

## See also

- `docs/sjon-reference.md` — the authoring reference for every form
- `schema/pngine.sjon` — the schema these programs are validated against
