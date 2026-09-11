// The lit half: the same two objects from the camera, shadow-sampled. This
// root declares the three bindings, two of which fill the holes
// ./shadow_pcf.wgsl left open (`t_shadow` and `s_shadow`); the depth root
// declares none of them and does not import that file.
//
// It expects `Inputs`, `ColorVSOut`, `LIGHT_POS`, `colorVertex` and `groundPos`
// from ./shadow_scene.wgsl, and `shadowVisibility` from ./shadow_pcf.wgsl.

@group(0) @binding(0) var<uniform> u: Inputs;
@group(0) @binding(1) var t_shadow: texture_depth_2d;
@group(0) @binding(2) var s_shadow: sampler_comparison;

@vertex fn color_vs(
  @location(0) position: vec3f,
  @location(1) normal: vec3f
) -> ColorVSOut {
  return colorVertex(position, normal, u.time, u.aspect);
}

@fragment fn color_fs(in: ColorVSOut) -> @location(0) vec4f {
  let n = normalize(in.fragNorm);
  let lightDir = normalize(LIGHT_POS - in.worldPos);
  let lambertian = max(dot(n, lightDir), 0.0);
  let visibility = shadowVisibility(in.shadowPos);

  let albedo = vec3f(0.9);
  // Base shape lighting (always visible, no shadows)
  let wrap = max(dot(n, normalize(LIGHT_POS)), 0.0) * 0.3;
  let fill = 0.15 + 0.1 * (0.5 + 0.5 * n.y);
  // Direct light gated by shadow visibility
  let direct = visibility * lambertian * 0.7;
  let lighting = min(fill + wrap + direct, 1.0);
  return vec4f(lighting * albedo, 1.0);
}

@vertex fn ground_color_vs(@builtin(vertex_index) i: u32) -> ColorVSOut {
  return colorVertex(groundPos(i), vec3f(0.0, 1.0, 0.0), u.time, u.aspect);
}

@fragment fn ground_color_fs(in: ColorVSOut) -> @location(0) vec4f {
  let n = vec3f(0.0, 1.0, 0.0);
  let lightDir = normalize(LIGHT_POS - in.worldPos);
  let lambertian = max(dot(n, lightDir), 0.0);
  let visibility = shadowVisibility(in.shadowPos);

  // Checkerboard pattern on ground
  let uv = floor(in.worldPos.xz * 0.1);
  let checker = ((uv.x + uv.y) % 2.0 + 2.0) % 2.0;
  let albedo = mix(vec3f(0.4), vec3f(0.7), checker);

  let fill = 0.15;
  let direct = visibility * lambertian * 0.7;
  let lighting = min(fill + direct, 1.0);
  return vec4f(lighting * albedo, 1.0);
}
