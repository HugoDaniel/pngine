#!/bin/bash
# Build CLI + WASM and compile all gallery samples to zig-out/playground/
#
# NOTE: this writes to zig-out/, a build output — nothing here is committed, so
# nothing here can rot in git. The committed twin of this script left with the
# docs site in §302 (site-pngine's scripts/build-shaders.sh), and its byte-exact
# drift gate left with it.
set -e

echo "==> Building CLI + WASM executors..."
zig build

# The webgpu_* payloads below were the gallery page's corpus; that page left the
# repo in 2026-08. They are kept because compiling every one of them on `npm run
# dev` is a broad smoke test that the examples still build, and because the
# playground loader serves the handful it links from this same directory.
echo "==> Compiling example PNGs..."
CLI=./zig-out/bin/pngine
OUT=zig-out/playground

$CLI examples/webgpu_hello_triangle.sjon    -o $OUT/hello_triangle.png
$CLI examples/webgpu_instanced_cubes.sjon   -o $OUT/instanced_cubes.png
$CLI examples/webgpu_points.sjon            -o $OUT/points.png
$CLI examples/webgpu_textured_cube.sjon     -o $OUT/textured_cube.png
$CLI examples/webgpu_particles.sjon         -o $OUT/particles.png
$CLI examples/rotating_cube.sjon            -o $OUT/rotating_cube.png
$CLI examples/boids.sjon                    -o $OUT/boids.png
$CLI examples/webgpu_fractal_cube.sjon      -o $OUT/fractal_cube.png
$CLI examples/webgpu_render_bundles.sjon    -o $OUT/render_bundles.png
$CLI examples/webgpu_stencil_mask.sjon     -o $OUT/stencil_mask.png
$CLI examples/webgpu_occlusion_query.sjon   -o $OUT/occlusion_query.png
$CLI examples/webgpu_timestamp_query.sjon   -o $OUT/timestamp_query.png
$CLI examples/webgpu_arcball_camera.sjon   -o $OUT/arcball_camera.png
$CLI examples/webgpu_primitive_picking.sjon -o $OUT/primitive_picking.png
$CLI examples/webgpu_shadow_mapping.sjon    -o $OUT/shadow_mapping.png
$CLI examples/webgpu_deferred_rendering.sjon   -o $OUT/deferred_rendering.png
$CLI examples/webgpu_marching_cubes.sjon    -o $OUT/marching_cubes.png

# --- Front-page demo examples (index.html links these by filename). They MUST be
# rebuilt here or they rot: stale PNGs carry an old embedded executor/bytecode and
# render black / throw at runtime (journal §205). rotating_cube + boids above
# double as front-page examples; demo2025.png is a multi-file demo
# (examples/demo2025/) with no single-.sjon build and is left as a committed artifact.
$CLI examples/simple_triangle.sjon          -o $OUT/simple_triangle.png
$CLI examples/moving_triangle.sjon          -o $OUT/moving_triangle.png

# The one pNGf (--flat) payload the served tree carries. mini.js is the tier the
# leak gates could not reach until §349 — it has no getStats() and no worker, so
# tests/e2e/leaks/mini-stability.spec.js instruments GPUDevice.prototype instead
# and needs a real flat payload to play. moving_triangle is chosen because it
# writes pngine-inputs every frame (the time-uniform arm) on top of the pass.
$CLI examples/moving_triangle.sjon --flat   -o $OUT/moving_triangle_flat.png

echo "==> Syncing playground assets..."

# Copy ALL JS modules to the playground so zig-out/playground/ is self-contained
# (fallback for non-Vite serving + worker resolution). A glob, NOT a hand-list:
# forgetting a newly-added module here shipped a broken demo during the JS arc
# (missing descriptor-decode.js -> gpu.js 500). index.js is also exposed as
# pngine.js (the demo's public entry point). See journal §204.
cp npm/pngine/src/*.js "$OUT/"
cp npm/pngine/src/index.js "$OUT/pngine.js"

# Copy fallback WASM (used by init.js path when PNG has no embedded executor)
cp npm/pngine/wasm/pngine.wasm $OUT/pngine.wasm 2>/dev/null || true

echo "==> Done. Run 'npm run dev' then open http://localhost:5173/"
