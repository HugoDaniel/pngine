// The ground plane: a flat lit quad under the mesh, drawn from a vertex
// buffer. Byte-identical in both documents. Imports ./mc_mvp.wgsl.

@group(0) @binding(0) var<storage, read> mvp: MVPData;

struct VSOut {
  @builtin(position) position: vec4f,
  @location(0) normal: vec3f,
  @location(1) worldPos: vec3f,
}

@vertex
fn vs(@location(0) pos: vec3f, @location(1) normal: vec3f) -> VSOut {
  var out: VSOut;
  let worldPos = vec3f(pos.x, pos.y - 12.0, pos.z);
  out.position = mvp.matrix * vec4f(worldPos, 1.0);
  out.normal = normal;
  out.worldPos = worldPos;
  return out;
}

@fragment
fn fs(in: VSOut) -> @location(0) vec4f {
  let N = normalize(in.normal);
  let L = normalize(vec3f(0.4, 0.8, 0.3));
  let diff = max(dot(N, L), 0.0);
  let ambient = 0.08;
  let color = vec3f(0.35, 0.35, 0.38) * (ambient + diff * 0.5);
  return vec4f(color, 1.0);
}
