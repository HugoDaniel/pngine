// Perspective projection. Column-major, WebGPU clip space: z in [0, 1], y down
// after the viewport transform. `fovy` is a vertical field of view in radians.
// Split out of lib/camera.wgsl in §402.

fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) -> mat4x4f {
  let f = 1.0 / tan(fovy * 0.5);
  let nf = 1.0 / (near - far);
  return mat4x4f(
    vec4f(f / aspect, 0.0, 0.0, 0.0),
    vec4f(0.0, f, 0.0, 0.0),
    vec4f(0.0, 0.0, far * nf, -1.0),
    vec4f(0.0, 0.0, far * near * nf, 0.0));
}
