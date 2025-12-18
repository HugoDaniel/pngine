struct PngineInputs {
  time: f32,
  canvasW: f32,
  canvasH: f32,
  canvasRatio: f32,
};

struct SceneQInputs {
  shape_attraction: f32,
};

// Note: This will be auto-detected as builtin and populated
@group(0) @binding(0) var<uniform> pngine: PngineInputs;
@group(0) @binding(1) var<uniform> camera : mat4x4<f32>;
@group(0) @binding(4) var<uniform> inputs : SceneQInputs;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
}

@vertex
fn vs_starfield(@builtin(vertex_index) vertexIndex: u32,
  @location(0) a_particlePos : vec4f,
  @location(1) a_particleVel : vec4f
) -> VertexOutput {
  // Single quad corners:
  const corners = array(
    vec2f(-0.5, -0.5),
    vec2f(-0.5,  0.5),
    vec2f( 0.5, -0.5),
    vec2f( 0.5,  0.5),
  );
  var output: VertexOutput;
  var shape_attraction = inputs.shape_attraction;
  let beat = pngine.time * BEAT_SECS;
  shape_attraction = shape_attraction_bpm(beat);

  let spriteSize = vec2f(0.08, 0.08) * (1.0 + 0.0 * shape_attraction);
  // let quadCenter = (a_particlePos.xy * 2.0 - vec2f(1.0)) * vec2f(0.9, 0.9);
  let quadCenter = a_particlePos.xy * vec2f(0.9, 0.9);
  let local = corners[vertexIndex] * spriteSize + quadCenter;
  let worldPos = vec4f(local, a_particlePos.z, 1.0);
  output.position = camera * worldPos;

  output.uv = corners[vertexIndex] * vec2f(1.0, -1.0) + vec2f(0.5); 

  return output;
}

const SCENE_START_BPM = 1.0;
const shapeAttractionStart = SCENE_START_BPM;
const offTime = shapeAttractionStart + 2.0;
fn shape_attraction_bpm(beat: f32) -> f32 {
  let compass = 4.0; // 1 compass = 4 beats

  let start = SCENE_START_BPM + 0.0;
  let t1 = smoothstep(0.0, 1.0, progress(beat, compass * start, compass * (start + 1.0)));
  var value = mix(0.0, 1.0, t1);

  let start2 = offTime;
  let param2 = progress(beat, compass * start2, compass * (start2 + 1.0));
  let t2 = (sin(param2 * PI - PI * 0.5) + 1.0) / 2.0;
  value = mix(value, 0.0, t2);

  return value;
}


@group(0) @binding(2) var starTexture: texture_2d<f32>;
@group(0) @binding(3) var starSampler: sampler;
@fragment
fn fs_starfield(fsInput: VertexOutput) -> @location(0) vec4f {
  let t = pngine.time;
  let uv = fsInput.uv;

  // Center coordinates
  let center = uv - vec2f(0.5);

  var col = textureSample(starTexture, starSampler, uv);

  return col;
  // return vec4f(0.0, 0.0, 0.0, 1.0);
}
