// Analytic inverse of lib/perspective.wgsl's `perspective` (P * invP = I):
// swap the diagonal reciprocals, move the -1. Takes the same arguments, so the
// two are read together. Three documents shared this body (§399).

fn invPerspective(fovy: f32, aspect: f32, near: f32, far: f32) -> mat4x4f {
  let f = 1.0 / tan(fovy * 0.5);
  let nf = 1.0 / (near - far);
  let a = far * nf;
  let b = far * near * nf;
  return mat4x4f(
    vec4f(aspect / f, 0, 0, 0),
    vec4f(0, 1.0 / f, 0, 0),
    vec4f(0, 0, 0, 1.0 / b),
    vec4f(0, 0, -1, a / b));
}
