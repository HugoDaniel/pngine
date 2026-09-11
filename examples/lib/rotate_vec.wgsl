// Rodrigues' rotation: turn `v` about a UNIT `axis` by `angle` radians. Three
// documents shared this body (§399).

fn rotateVec(v: vec3f, axis: vec3f, angle: f32) -> vec3f {
  let c = cos(angle);
  let s = sin(angle);
  return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}
