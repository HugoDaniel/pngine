// The scene half of the shadow-mapping pair: everything both the depth roots
// and the lit roots need, and nothing that binds a resource. The light and the
// camera are derived, not uploaded, so the only binding either document has is
// the 16-byte pngine-inputs uniform its lit root declares.
//
// `getCameraVP` writes PI without declaring it: the compiler substitutes the
// math constants PI/TAU/E into shader text, and it does that over the assembled
// module, so a fragment may use them exactly as inline code does.
//
// Imports ./perspective.wgsl and ./look_at.wgsl.

const LIGHT_POS = vec3f(80.0, 50.0, -60.0);

struct Inputs {
  time: f32,
  width: f32,
  height: f32,
  aspect: f32,
};

// The vertex output the two lit entry points share. The depth roots never
// mention it; assembling it into them costs nothing, because dead-code
// elimination runs after the module is one text.
struct ColorVSOut {
  @builtin(position) pos: vec4f,
  @location(0) shadowPos: vec3f,
  @location(1) fragNorm: vec3f,
  @location(2) worldPos: vec3f,
};

fn ortho(l: f32, r: f32, b: f32, tp: f32, n: f32, f: f32) -> mat4x4f {
  let rml = 1.0 / (r - l);
  let tmb = 1.0 / (tp - b);
  let fmn = 1.0 / (f - n);
  return mat4x4f(
    vec4f(2.0 * rml, 0.0, 0.0, 0.0),
    vec4f(0.0, 2.0 * tmb, 0.0, 0.0),
    vec4f(0.0, 0.0, -fmn, 0.0),
    vec4f(-(r + l) * rml, -(tp + b) * tmb, -n * fmn, 1.0));
}

fn getLightVP() -> mat4x4f {
  let view = lookAt(LIGHT_POS, vec3f(0.0, 0.0, 0.0), vec3f(0.0, 1.0, 0.0));
  let proj = ortho(-80.0, 80.0, -80.0, 80.0, -200.0, 300.0);
  return proj * view;
}

fn getCameraVP(t: f32, aspect: f32) -> mat4x4f {
  let angle = PI * (t / 2.0);
  let center = vec3f(0.0, 60.0, 0.0);
  let eye = center + vec3f(120.0 * sin(angle), 3.0, -120.0 * cos(angle));
  let view = lookAt(eye, center, vec3f(0.0, 1.0, 0.0));
  let proj = perspective(PI * 2.0 / 5.0, aspect, 0.5, 2000.0);
  return proj * view;
}

// Ground plane: a vertex-generated quad on the XZ plane, no vertex buffer.
const GROUND_Y = 20.0;
const GROUND_HALF = 100.0;

fn groundPos(i: u32) -> vec3f {
  // 6 vertices: two CCW triangles forming a quad on the XZ plane at y=GROUND_Y
  //   0: (-H, Y, -H)  1: (H, Y, -H)  2: (H, Y, H)
  //   3: (-H, Y, -H)  4: (H, Y, H)   5: (-H, Y, H)
  let idx = array<vec2f, 6>(
    vec2f(-1, -1), vec2f(1, -1), vec2f(1, 1),
    vec2f(-1, -1), vec2f(1, 1),  vec2f(-1, 1));
  let xz = idx[i] * GROUND_HALF;
  return vec3f(xz.x, GROUND_Y, xz.y);
}

// The lit vertex transform, shared by the dragon and the ground. Taking time
// and aspect as parameters is what keeps this out of the uniform: the root
// owns the binding and passes the two fields.
fn colorVertex(pos: vec3f, normal: vec3f, t: f32, aspect: f32) -> ColorVSOut {
  let worldPos = vec4f(pos, 1.0);
  let cameraVP = getCameraVP(t, aspect);
  let lightClip = getLightVP() * worldPos;
  var out: ColorVSOut;
  out.pos = cameraVP * worldPos;
  out.shadowPos = vec3f(
    lightClip.xy * vec2f(0.5, -0.5) + vec2f(0.5),
    lightClip.z);
  out.fragNorm = normal;
  out.worldPos = pos;
  return out;
}
