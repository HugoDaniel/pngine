// The lit half: 3x3 percentage-closer filtering over a depth map. It samples
// two bindings it does not declare — `t_shadow` and `s_shadow` are holes the
// root fills, which is what keeps this file out of the depth roots that have no
// bindings at all. `:requires [t_shadow s_shadow]` on the (wgsl …) form is
// where those two names are written down.
//
// SHADOW_SIZE_F is the kernel's idea of the map's resolution, not the map's
// actual size: webgpu_shadow_mapping renders a 256² map and filters it as if it
// were 1024², which is the low-resolution half of the pair.

const SHADOW_SIZE_F = 1024.0;

fn shadowVisibility(shadowPos: vec3f) -> f32 {
  let texelSize = 1.0 / SHADOW_SIZE_F;
  var visibility = 0.0;
  for (var y = -1; y <= 1; y++) {
    for (var x = -1; x <= 1; x++) {
      let offset = vec2f(f32(x), f32(y)) * texelSize;
      visibility += textureSampleCompare(
        t_shadow, s_shadow,
        shadowPos.xy + offset, shadowPos.z - 0.007);
    }
  }
  return visibility / 9.0;
}
