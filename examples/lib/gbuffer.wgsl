// The G-buffer library: what a deferred renderer's write roots and its lighting
// root both have to agree about. Sharing it is not a convenience here — the
// camera matrix MUST be the same function in the passes that write the G-buffer
// and in the pass that reconstructs world positions from it, or the lighting
// lands in the wrong place. webgpu_deferred_rendering.sjon says so in a comment
// ("must match gBufferShader exactly") over a hand-kept copy; this file is that
// comment made structural.
//
// Nothing here binds a resource: `getCameraVP` takes time and aspect as
// parameters, so each root declares its own uniform and passes the two fields.
//
// Imports ./perspective.wgsl and ./look_at.wgsl.

struct Inputs {
  time: f32,
  width: f32,
  height: f32,
  aspect: f32,
}

// What the two G-buffer write roots rasterise, and what their fragment stages
// receive.
struct VSOut {
  @builtin(position) pos: vec4f,
  @location(0) normal: vec3f,
  @location(1) worldPos: vec3f,
}

// The MRT attachment pair: @location(0) is the rgba16float normal target,
// @location(1) the rgba8unorm albedo target.
struct GBufferOut {
  @location(0) normal: vec4f,
  @location(1) albedo: vec4f,
}

fn getCameraVP(t: f32, aspect: f32) -> mat4x4f {
  let angle = t * 0.2;
  let center = vec3f(0.0, 60.0, 0.0);
  let eye = center + vec3f(120.0 * sin(angle), 3.0, -120.0 * cos(angle));
  let view = lookAt(eye, center, vec3f(0.0, 1.0, 0.0));
  let proj = perspective(PI * 2.0 / 5.0, aspect, 1.0, 2000.0);
  return proj * view;
}

// Ground plane: a vertex-generated quad on the XZ plane, no vertex buffer.
const GROUND_Y = 20.0;
const GROUND_HALF = 100.0;

fn groundPos(i: u32) -> vec3f {
  let idx = array<vec2f, 6>(
    vec2f(-1, -1), vec2f(1, -1), vec2f(1, 1),
    vec2f(-1, -1), vec2f(1, 1),  vec2f(-1, 1));
  let xz = idx[i] * GROUND_HALF;
  return vec3f(xz.x, GROUND_Y, xz.y);
}
