// The marching-cubes document's instance of the scalar field: an animated
// rounded box smooth-unioned with a torus, spun about Y.
//
// It supplies the two names the shared library leaves open. `field` is the
// NEGATED distance, because the library's grid and triangle table read
// positive as inside while a signed distance function reads it as outside;
// negating here is what lets one density root and one vertex generator serve
// both documents. `ambientOcclusion` marches the distance field, which is a
// thing only a distance function can do — the metaball instance answers 1.0.
//
// `pngine` is a hole: the uniform is declared by whichever root imports this.

fn sdTorus(p: vec3f, t: vec2f) -> f32 {
  let q = vec2f(length(p.xz) - t.x, p.y);
  return length(q) - t.y;
}
fn udRoundBox(p: vec3f, b: vec3f, r: f32) -> f32 {
  return length(max(abs(p) - b, vec3f(0.0))) - r;
}
fn opSmoothUnion(a: f32, b: f32, k: f32) -> f32 {
  let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
  return mix(b, a, h) - k * h * (1.0 - h);
}
fn rotateY(p: vec3f, a: f32) -> vec3f {
  let c = cos(a); let s = sin(a);
  return vec3f(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
}
fn sdf(p: vec3f, t: f32) -> f32 {
  let rp = rotateY(p, t * 0.3);
  let box_d = udRoundBox(rp, vec3f(4.0, 4.0, 4.0), 0.5);
  let torus_r = 8.0 + 2.0 * sin(t * 0.7);
  let torus_d = sdTorus(rp, vec2f(torus_r, 2.0));
  return opSmoothUnion(box_d, torus_d, 2.0);
}

fn field(p: vec3f, t: f32) -> f32 {
  return -sdf(p, t);
}

// Simplified AO: sample density in a few directions
fn ambientOcclusion(pos: vec3f, normal: vec3f) -> f32 {
  var ao = 0.0;
  let step_size = 1.5;
  for (var i = 1u; i <= 5u; i++) {
    let dist = f32(i) * step_size;
    let sample_pos = pos + normal * dist;
    let d = sdf(sample_pos, pngine.time);
    ao += max(0.0, dist - d) / dist;
  }
  return clamp(1.0 - ao * 0.3, 0.0, 1.0);
}
