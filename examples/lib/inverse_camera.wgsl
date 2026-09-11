// A view matrix from an orthonormal basis and an eye position: the transpose of
// the rotation, with the translation projected onto it. Column-major, WebGPU
// clip space. Five documents shared this body (§399).

fn inverseCamera(r: vec3f, u: vec3f, b: vec3f, p: vec3f) -> mat4x4f {
  return mat4x4f(
    vec4f(r.x, u.x, b.x, 0),
    vec4f(r.y, u.y, b.y, 0),
    vec4f(r.z, u.z, b.z, 0),
    vec4f(-dot(r, p), -dot(u, p), -dot(b, p), 1));
}
