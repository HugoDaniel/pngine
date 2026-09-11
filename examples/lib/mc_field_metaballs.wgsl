// The metaballs document's instance of the same two names. Six balls orbit on
// golden-angle-decorrelated Lissajous paths and their inverse-square field is
// already positive inside, so `field` needs no sign flip.
//
// `ambientOcclusion` returns 1.0. The marching-cubes instance marches its
// distance function for it; a metaball field is not a distance, so there is
// nothing to march — and rather than the shared vertex generator carrying an
// `if` about which document it is in, the answer is one line here.

const K: u32 = 6u;
const THRESHOLD: f32 = 1.0;

fn ballCenter(i: u32, t: f32) -> vec3f {
  let phase = f32(i) * 2.399963;             // golden-angle decorrelation
  let sp = vec3f(0.9, 1.3, 1.1) * (0.4 + 0.13 * f32(i));
  return vec3f(sin(t * sp.x + phase),
               sin(t * sp.y + phase * 1.7),
               sin(t * sp.z + phase * 2.3)) * 9.0;   // stay inside the 33^3 grid
}

// Inverse-square metaball field, positive inside (f > 0 <=> inside surface).
fn field(p: vec3f, t: f32) -> f32 {
  var f = 0.0;
  for (var i = 0u; i < K; i++) {
    let d = p - ballCenter(i, t);
    let r2 = 8.0 + 3.0 * f32(i % 3u);        // ball radii ~2.8..3.3
    f += r2 / max(dot(d, d), 1e-4);
  }
  return f - THRESHOLD;
}

fn ambientOcclusion(pos: vec3f, normal: vec3f) -> f32 {
  return 1.0;
}
