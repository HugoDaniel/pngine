//! simpleTriangle SJON fixture for testing and benchmarks.
//!
//! This is the hand-written SJON for the simplest PNGine example:
//! a red triangle rendered to a canvas. It mirrors
//! examples/simple_triangle.sjon (which the golden-trace suite covers);
//! this copy exists so library consumers (benchmarks, tests) have a
//! dependency-free source fixture.

/// Complete simpleTriangle SJON source.
pub const simple_triangle_sjon: [:0]const u8 =
    \\(shader-module :name code :code """
    \\@vertex
    \\fn vertexMain(
    \\  @builtin(vertex_index) VertexIndex : u32
    \\) -> @builtin(position) vec4f {
    \\  var pos = array<vec2f, 3>(
    \\    vec2(0.0, 0.5),
    \\    vec2(-0.5, -0.5),
    \\    vec2(0.5, -0.5)
    \\  );
    \\  return vec4f(pos[VertexIndex], 0.0, 1.0);
    \\}
    \\
    \\@fragment
    \\fn fragMain() -> @location(0) vec4f {
    \\  return vec4(1.0, 0.0, 0.0, 1.0);
    \\}
    \\""")
    \\
    \\(render-pipeline :name pipeline
    \\  (layout auto)
    \\  (vertex (module code) (entry vertexMain))
    \\  (fragment (module code) (entry fragMain)
    \\    (targets (target :format preferred-canvas-format)))
    \\  (primitive (topology triangle-list)))
    \\
    \\(render-pass :name renderPipeline
    \\  (color-attachment :view context-current-texture :clear-value [0 0 0 0] :load-op clear :store-op store)
    \\  :pipeline pipeline
    \\  (draw :vertex-count 3))
    \\
    \\(frame :name simpleTriangle :perform [renderPipeline])
    \\
;

const std = @import("std");
