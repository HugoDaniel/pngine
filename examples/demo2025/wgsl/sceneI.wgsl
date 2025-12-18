struct PngineInputs {
  time: f32,
  canvasW: f32,
  canvasH: f32,
  canvasRatio: f32,
};

struct SceneIInputs {
  something_t: f32,
}

@group(0) @binding(0) var<uniform> pngine: PngineInputs;
@group(0) @binding(1) var<uniform> inputs: SceneIInputs;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
  @location(1) correctedUv: vec2f,
}

@vertex
fn vs_sceneI(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
  var pos = array(
    vec2f(-1.0, -1.0),
    vec2f(-1.0,  3.0),
    vec2f( 3.0, -1.0),
  );

  var output: VertexOutput;
  let xy = pos[vertexIndex];
  output.position = vec4f(xy, 0.0, 1.0);
  output.uv = xy * vec2f(0.5, -0.5) + vec2f(0.5);
  // Aspect-ratio correction in vertex shader
  var corrected = output.uv * 2.0 - 1.0;  // Center to [-1, 1]

  // Normalize UV space so 1 unit == min(canvasW, canvasH) in pixels
  let minDim = min(pngine.canvasW, pngine.canvasH);
  let scale = vec2f(pngine.canvasW / minDim, pngine.canvasH / minDim);
  corrected *= scale;

  output.correctedUv = corrected;

  let beat = pngine.time * BEAT_SECS;

  return output;
}

struct SDFResult {
  dist: f32,
  color: vec3f,
}

fn scene_sdf(p: vec2f, transform: Transform2D) -> SDFResult {
  let q = transform_to_local(p, transform);
  let left = -1.0 * pngine.canvasRatio;
  let right = 1.0 * pngine.canvasRatio;

  var result = SDFResult(1e10, vec3f(0.0));

  result.dist = box(q, vec2f(0.25, 0.25));
  result.color = vec3f(1.0, 0.7, 0.9);

  return result;
}

fn render(fsInput: VertexOutput, time: f32, transform: Transform2D) -> vec3f {
  let correctedUv = fsInput.correctedUv;  // Aspect-corrected UV for shapes

  let sdf = scene_sdf(correctedUv, transform);
  let d = sdf.dist;

  if (d > 0.0) {
    return background(correctedUv, time);
  }

  return sdf.color;
}

fn background(uv: vec2f, t: f32) -> vec3f {
  // Expanding light
  let center = uv - vec2f(0.5);
  let dist = length(center);
  let pulse = sin(t * 5.0) * 0.3 + 0.7;

  let expand = 1.0 - smoothstep(0.0, pulse, dist);

  let white = vec3f(1.0, 1.0, 1.0);
  let gray = vec3f(0.2, 0.2, 0.2);

  let color = mix(gray, white, expand);

  return color;
}

@fragment
fn fs_sceneI(fsInput: VertexOutput) -> @location(0) vec4f {
  let t = pngine.time;
  let uv = fsInput.uv;

  let something = inputs.something_t;

  var sceneTransform: Transform2D;
  sceneTransform.pos = vec2f(0.0, 0.0);
  sceneTransform.anchor = vec2f(0.0, 0.0);
  sceneTransform.angle = 0.0;
  sceneTransform.scale = vec2f(1.0, 1.0);
  var color = render(fsInput, t, sceneTransform);

  color = pow(color, vec3f(2.2));

  return vec4f(color, 1.0);
}
