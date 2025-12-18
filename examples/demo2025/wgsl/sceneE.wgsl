struct PngineInputs {
  time: f32,
  canvasW: f32,
  canvasH: f32,
  canvasRatio: f32,
};

struct SceneEInputs {
  sq_t: f32,
  neon: f32,
  bg_shape_t: f32,
  px: f32,
}

@group(0) @binding(0) var<uniform> pngine: PngineInputs;
@group(0) @binding(1) var<uniform> inputs: SceneEInputs;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
  @location(1) correctedUv: vec2f,

  @location(2) sq_t: f32,
  @location(3) neon: f32,
  @location(4) bg_shape_t: f32,
  @location(5) px: f32,
}

@vertex
fn vs_sceneE(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
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
  output.sq_t = sq_bpm(beat);
  output.neon = neon_bpm(beat);
  output.bg_shape_t = bg_shape_bpm(beat);
  output.px = px_bpm(beat);

  return output;
}

fn px_bpm(original_beat: f32) -> f32 {
  let phase = floor(original_beat / 4.0) % 8.0;
  let beat = original_beat / 2.0;

  // Shared Constants
  let OFF = 1.0;
  let MID = 0.5;
  let ON = 0.0;

  var value: f32;

  switch u32(phase) {
      case 4u,6u: {
        let b1 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b2 = vec4f(MID, 2.0, 0.0, 0.0);
        let b3 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b4 = vec4f(MID, 2.0, 0.0, 0.0);

        value = bar4(beat, b1, b2, b3, b4);
      }
      case 5u,7u: {
        let b1 = vec4f(MID, 2.0, 0.0, 0.0);
        let b2 = vec4f(ON, 2.0, 0.0, 0.0);
        let b3 = vec4f(MID, 2.0, 0.0, 0.0);
        let b4 = vec4f(ON, 2.0, 0.0, 0.0);

        value = bar4(beat, b1, b2, b3, b4);
      }
      default: {
        let b1 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b2 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b3 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b4 = vec4f(OFF, 2.0, 0.0, 0.0);

        value = bar4(beat, b1, b2, b3, b4);
      }
  }

  return value;
}

fn neon_bpm(beat: f32) -> f32 {
  let phase = floor(beat / 4.0) % 4.0;

  // Shared Constants
  let OFF = 0.0;
  let ON = 1.0;

  var value: f32;

  switch u32(phase) {
      case 0u: {
        let b1 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b2 = vec4f(ON, 2.0, 0.0, 0.0);
        let b3 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b4 = vec4f(ON, 2.0, 0.0, 0.0);

        value = bar4(beat, b1, b2, b3, b4);
      }
      case 2u: {
        let b1 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b2 = vec4f(ON, 2.0, 0.0, 0.0);
        let b3 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b4 = vec4f(ON, 2.0, 0.0, 0.0);

        value = bar4(beat, b1, b2, b3, b4);
      }
      default: {
        let b1 = vec4f(ON, 2.0, 0.0, 0.0);
        let b2 = vec4f(ON, 2.0, 0.0, 0.0);
        let b3 = vec4f(ON, 2.0, 0.0, 0.0);
        let b4 = vec4f(ON, 2.0, 0.0, 0.0);

        value = bar4(beat, b1, b2, b3, b4);
      }
  }

  return value;
}
fn bg_shape_bpm(beat: f32) -> f32 {
  let phase = floor(beat / 4.0) % 4.0;

  // Shared Constants
  let OFF = 0.1;
  let MID = 0.4;
  let HIGH = 0.6;

  var value: f32;

  switch u32(phase) {
      case 0u: {
        let b1 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b2 = vec4f(MID, 2.0, 0.0, 0.0);
        let b3 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b4 = vec4f(HIGH, 2.0, 0.0, 0.0);

        value = bar4(beat, b1, b2, b3, b4);
      }
      case 2u: {
        let b1 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b2 = vec4f(MID, 2.0, 0.0, 0.0);
        let b3 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b4 = vec4f(HIGH, 2.0, 0.0, 0.0);

        value = bar4(beat, b1, b2, b3, b4);
      }
      default: {
        let b1 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b2 = vec4f(MID, 2.0, 0.0, 0.0);
        let b3 = vec4f(OFF, 2.0, 0.0, 0.0);
        let b4 = vec4f(MID, 2.0, 0.0, 0.0);

        value = bar4(beat, b1, b2, b3, b4);
      }
  }

  return value;
}

fn sq_bpm(original_beat: f32) -> f32 {
  let phase = floor(original_beat / 4.0) % 4.0;

  let beat = original_beat / 4.0;

  // Shared Constants
  let Q0 = 0.0;
  let Q1 = 0.333;
  let Q2 = 0.666;
  let Q3 = 1.0;

  var value: f32;

  switch u32(phase) {
      case 0u: {
        let b1 = vec4f(Q0, 2.0, 0.0, 0.0);
        let b2 = vec4f(Q1, 2.0, 0.0, 0.0);
        let b3 = vec4f(Q2, 2.0, 0.0, 0.0);
        let b4 = vec4f(Q3, 2.0, 0.0, 0.0);

        value = bar4(beat, b1, b2, b3, b4);
      }
      case 2u: {
        let b1 = vec4f(Q0, 2.0, 0.0, 0.0);
        let b2 = vec4f(Q1, 2.0, 0.0, 0.0);
        let b3 = vec4f(Q2, 2.0, 0.0, 0.0);
        let b4 = vec4f(Q3, 2.0, 0.0, 0.0);

        value = bar4(beat, b1, b2, b3, b4);
      }
      default: {
        let b1 = vec4f(Q0, 2.0, 0.0, 0.0);
        let b2 = vec4f(Q1, 2.0, 0.0, 0.0);
        let b3 = vec4f(Q2, 2.0, 0.0, 0.0);
        let b4 = vec4f(Q3, 2.0, 0.0, 0.0);

        value = bar4(beat, b1, b2, b3, b4);
      }
  }

  return value;
}
fn background(fsInput: VertexOutput, p: vec2f, t: f32) -> vec4f {
  // let q = pixelate_uv(p, 40.0);
  let q = p;
  // Radial pattern
  let center = q; // p - vec2f(0.5);
  let angle = atan2(center.y, center.x);
  let radius = length(center);

  let pattern = mix(0.5, 2.0,
    (sin(t) + 1.0) / 2.0) * sin(angle * 8.0 + t * 3.0) + 0.5;
  let radial = 1.0 - radius * 0.25;

  // Neon-style pink/yellow palette
  let babyPink = vec4f(1.0, 0.75, 0.85, 1.0);
  let toastedYellow = vec4f(0.9, 0.7, 0.2, 1.0);

  let mixture = pattern * radial;
  // let bg_shape = box(p, vec2f(0.9 * inputs.bg_shape_t));
  let bg_shape_transf = Transform2D(vec2f(), 0.0, vec2f(-fsInput.bg_shape_t * 2.0), vec2f());
  let bg_shape = catFaceLogo2(p, BOB_SIZE.x, 0.0, bg_shape_transf);

  // let bg_col = mix(toastedYellow, babyPink, bg_shape);
  let bg_col = mix(toastedYellow, babyPink, mixture);

  // return bg_col * smoothstep(0.0, inputs.bg_shape_t, bg_shape); 
  return bg_col * smoothstep(0.0, 0.01, bg_shape); 
}

struct SDFResult {
  dist: f32,
  color: vec4f,
}

// Box Of Boxes
const BS = vec2f(0.3333);
const BOB_HALF_SIZE = BS / 3.0;
const BOB_SIZE = BOB_HALF_SIZE * 2.0;

const colors = array<vec3f, 9>(
  vec3f(0.0, 1.0, 0.0), vec3f(0.5, 0.7, 0.8), vec3f(0.8, 0.3, 0.8),
  vec3f(0.9, 0.2, 0.1), vec3f(0.8, 0.2, 0.3), vec3f(0.3, 0.43, 0.77),
  vec3f(0.5, 0.5, 0.7), vec3f(0.2, 0.1, 0.7), vec3f(0.1, 0.9, 0.75),
);

fn animT(t: f32) -> f32 {
  const iterations = 3.0;

  return fract(t * iterations);
}

fn box_of_boxes(fsInput: VertexOutput, p: vec2f, transform: Transform2D) -> SDFResult {
  let q = transform_to_local(p, transform);
  let left = -1.0 * pngine.canvasRatio;
  let right = 1.0 * pngine.canvasRatio;

  var result = SDFResult(AWAY, vec4f(0.0));

  let paramT = animT(fsInput.sq_t);

  // Calculate individual boxes SDF
  let k = mix(0.05, 0.0, smoothstep(0.0, 0.3, paramT));
  var individualBoxesDist = AWAY;

  let transforms = boxOfBoxesTransform(BOB_SIZE.x);
  for (var i = 0u; i < 9; i++) {
    var transf = transforms[i];
    var alpha = 1.0;
    if (i == 2) {
      let destAnchor = vec2f(BOB_SIZE.x * 2.0 , 2.0 *  -BOB_SIZE.y);
      let destAngle = PI / 2.0;
      transf = Transform2D(transf.pos, mix(0.0, destAngle, paramT), transf.scale, mix(vec2f(), destAnchor, paramT));
      alpha = 1.0;
    } else {
      transf.anchor = mix(vec2f(), f32(i) * transf.pos, smoothstep(0.0, 1.0, paramT));
      transf.angle = smoothstep(0.0, PI / 2.0, paramT);
      alpha = smoothstep(1.0, 0.0, clamp((paramT - 0.8) * 5.0, 0.0, 1.0));
    }
    let box_dist = transformedBox(q, BOB_HALF_SIZE, transf);

    individualBoxesDist = smin(box_dist, individualBoxesDist, k);
  }

  // Calculate single large square SDF
  let boundingBoxSize = BOB_HALF_SIZE * 3.0;
  let singleSquareDist = box(q, boundingBoxSize);

  // Blend between single square and individual boxes
  // Early in animation: pure square (no wobble)
  // Later: individual boxes become visible
  let blendFactor = smoothstep(0.0, 0.2, paramT);
  result.dist = mix(singleSquareDist, individualBoxesDist, blendFactor);

  return result;
}

fn scene_sdf(fsInput: VertexOutput, p: vec2f, transform: Transform2D) -> SDFResult {
  let q = transform_to_local(p, transform);
  let left = -1.0 * pngine.canvasRatio;
  let right = 1.0 * pngine.canvasRatio;

  let bobTransfFinal = Transform2D(vec2f(), PI, vec2f(3), 3.0 * vec2f(-BOB_SIZE.x * 3.0, -BOB_SIZE.y));
  let bobTransf = mixTransform(NO_TRANSFORM, bobTransfFinal, animT(fsInput.sq_t));
  var result = box_of_boxes(fsInput, q, bobTransf);

  return result;
}

fn render(fsInput: VertexOutput, time: f32, transform: Transform2D) -> vec4f {
  var correctedUv = fsInput.correctedUv;
  if (fsInput.px < 1.0) {
    correctedUv = pixelate_uv(fsInput.correctedUv, mix(4.0, 120.0, fsInput.px));  // Aspect-corrected UV for shapes
  }

  // Always render background first
  let bg = background(fsInput, correctedUv, time);

  let sdf = scene_sdf(fsInput, correctedUv, transform);
  var d = sdf.dist;


  var plainColor = bg * smoothstep(0.0, 0.01, d);

  var neon_d = 0.02 / d;
  let neonBoxColor = vec4f(neon_d, neon_d, neon_d, sdf.color.a);
  var neonColor = vec4f(
    mix(bg.rgb, neonBoxColor.rgb, neon_d),
    1.0
  );

  // return bg;
  return mix(plainColor, neonColor, vec4f(fsInput.neon));
}

@fragment
fn fs_sceneE(fsInput: VertexOutput) -> @location(0) vec4f {
  let t = pngine.time;
  let uv = fsInput.uv;

  let sq_t = inputs.sq_t;
  let neon = inputs.neon;
  let bg_shape_t = inputs.bg_shape_t;
  let px = inputs.px;

  var sceneTransform: Transform2D;
  sceneTransform.pos = vec2f(0.0, 0.0);
  sceneTransform.anchor = vec2f(0.0, 0.0);
  sceneTransform.angle = 0.0;
  sceneTransform.scale = vec2f(1.0, 1.0);
  var color = render(fsInput, t, sceneTransform);

  color = pow(color, vec4f(vec3f(2.2), 1.0));

  return color;
}
