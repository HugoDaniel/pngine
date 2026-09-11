// The mesh's own shading: Blinn-Phong with a fresnel rim and the per-vertex
// AO stage 3 baked into the vertex stream. Imports ./mc_mvp.wgsl; requires the
// three palette colours from whichever fragment the document supplies.

@group(0) @binding(0) var<storage, read> mvp: MVPData;

struct VSOut {
  @builtin(position) position: vec4f,
  @location(0) worldPos: vec3f,
  @location(1) normal: vec3f,
  @location(2) ao: f32,
}

@vertex
fn vs(@location(0) posAO: vec4f, @location(1) normalPad: vec4f) -> VSOut {
  var out: VSOut;
  out.position = mvp.matrix * vec4f(posAO.xyz, 1.0);
  out.worldPos = posAO.xyz;
  out.normal = normalPad.xyz;
  out.ao = posAO.w;
  return out;
}

@fragment
fn fs(in: VSOut) -> @location(0) vec4f {
  let N = normalize(in.normal);
  let L = normalize(vec3f(0.4, 0.8, 0.3));
  let V = normalize(mvp.camPos.xyz - in.worldPos);
  let H = normalize(L + V);

  // Normal-based color: one palette on top, another on the sides, a third
  // underneath. The three colours are HOLES: each document declares them as
  // module-scope consts, which is how the same shading serves a warm SDF
  // solid and a cold metaball blob. A WGSL `override` could not do this — an
  // override is a scalar, and these are vectors.
  let ny = N.y * 0.5 + 0.5; // 0=down, 1=up
  let top    = kTop;
  let side   = kSide;
  let bottom = kBottom;
  let mat = mix(mix(bottom, side, smoothstep(0.0, 0.4, ny)), top, smoothstep(0.5, 1.0, ny));

  let NdotL = dot(N, L);
  let diff = max(NdotL, 0.0);
  let back_diff = max(-NdotL, 0.0) * 0.15;
  let spec = pow(max(dot(N, H), 0.0), 48.0);
  let fresnel = pow(1.0 - max(dot(N, V), 0.0), 3.0) * 0.25;
  let ambient = 0.12;
  let color = mat * (ambient + diff * 0.75 + back_diff) + vec3f(0.9) * spec + vec3f(0.4, 0.5, 0.7) * fresnel;
  return vec4f(color * in.ao, 1.0);
}
