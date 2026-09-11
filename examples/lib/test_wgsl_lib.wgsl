// A plain .wgsl file. Nothing pngine-specific in it: no extension, no import
// statement, no conditional compilation. It opens in any editor and pastes into
// any other WGSL tool, which is the point of keeping fragments plain WGSL.
//
// `wave` calls a `phase` it does not declare — a hole the importing module
// fills. `:requires [phase]` on the (wgsl …) form is where that is written
// down, because a .wgsl file has nowhere to say it.

fn wave(uv: vec2f) -> f32 {
  return 0.5 + 0.5 * sin(uv.x * 10.0 + phase());
}

fn ripple(uv: vec2f, k: f32) -> f32 {
  let d = length(uv - vec2f(0.5));
  return 0.5 + 0.5 * sin(d * k - phase());
}
