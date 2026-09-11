// A view matrix from eye, target and up: the orthonormal basis transposed, with
// the translation projected onto it. Column-major, matching the convention
// lib/perspective.wgsl projects into. Split out of lib/camera.wgsl in §402.

fn lookAt(eye: vec3f, center: vec3f, up: vec3f) -> mat4x4f {
  let fwd = normalize(center - eye);
  let right = normalize(cross(fwd, up));
  let u2 = cross(right, fwd);
  return mat4x4f(
    vec4f(right.x, u2.x, -fwd.x, 0.0),
    vec4f(right.y, u2.y, -fwd.y, 0.0),
    vec4f(right.z, u2.z, -fwd.z, 0.0),
    vec4f(-dot(right, eye), -dot(u2, eye), dot(fwd, eye), 1.0));
}
