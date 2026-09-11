// The depth half of the shadow-mapping pair: the dragon and the ground drawn
// from the light's point of view, into the shadow map. Two vertex entry points,
// no fragment stage, and no bindings at all — the light's matrix is derived
// from a const in shadow_scene.wgsl, so `:layout auto` gives both pipelines an
// empty layout and neither depth pass sets a bind group.
//
// This is a ROOT, not a fragment: it declares entry points, so a
// (shader-module …) names it with `:file` and it becomes one GPUShaderModule.
// It expects `getLightVP` and `groundPos` from ./shadow_scene.wgsl.

@vertex fn shadow_vs(
  @location(0) position: vec3f,
  @location(1) _normal: vec3f
) -> @builtin(position) vec4f {
  return getLightVP() * vec4f(position, 1.0);
}

@vertex fn ground_shadow_vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  return getLightVP() * vec4f(groundPos(i), 1.0);
}
