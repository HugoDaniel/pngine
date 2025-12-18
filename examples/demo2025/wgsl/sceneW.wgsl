struct PngineInputs {
  time: f32,
  canvasW: f32,
  canvasH: f32,
  canvasRatio: f32,
};

struct SceneWInputs {
  eyelid_t: f32,
  cam_t: f32,
  tangram_visibility_t: f32,
  tangram_movement_t: f32,
  cam_rot_t: f32,
  video_visibility_t: f32,
  video_t: f32,
}

@group(0) @binding(0) var<uniform> pngine: PngineInputs;
@group(0) @binding(1) var<uniform> inputs: SceneWInputs;

// Video texture bindings
@group(1) @binding(0) var videoSampler: sampler;
@group(1) @binding(1) var videoTexture: texture_external;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
  @location(1) correctedUv: vec2f,
  @location(2) aaWidth: f32,
  @location(3) beat: vec2f,

  //
  @location(4) v_attr1: vec4f,
  // eyelid_t: f32,
  // cam_t: f32,
  // tangram_visibility_t: f32,
  // tangram_movement_t: f32,
  @location(5) v_attr2: vec4f,
  // cam_rot_t: f32,
  // video_visibility_t: f32,
  // video_t: f32,
  // bridge_visibility_t: f32,

  // Bridge params packed: (height1, height2, dist, train_mov)
  @location(6) bridge_params: vec4f,
  // Background params packed: (glow_t, bg_vis_t)
  @location(7) bg_params: vec2f,

  // Precomputed tangram transforms (pos.xy, angle) - vertex shader optimization
  @location(8) @interpolate(flat) t0: vec3f,
  @location(9) @interpolate(flat) t1: vec3f,
  @location(10) @interpolate(flat) t2: vec3f,
  @location(11) @interpolate(flat) t3: vec3f,
  @location(12) @interpolate(flat) t4: vec3f,
  @location(13) @interpolate(flat) t5: vec3f,
  @location(14) @interpolate(flat) t6: vec3f,
}

fn get_eyelid_t(i: VertexOutput) -> f32 { return i.v_attr1.x; }
fn get_cam_t(i: VertexOutput) -> f32 { return i.v_attr1.y; }
fn get_tangram_visibility_t(i: VertexOutput) -> f32 { return i.v_attr1.z; }
fn get_tangram_movement_t(i: VertexOutput) -> f32 { return i.v_attr1.w; }
fn get_cam_rot_t(i: VertexOutput) -> f32 { return i.v_attr2.x; }
fn get_video_visibility_t(i: VertexOutput) -> f32 { return i.v_attr2.y; }
fn get_video_t(i: VertexOutput) -> f32 { return i.v_attr2.z; }
fn get_bridge_visibility_t(i: VertexOutput) -> f32 { return i.v_attr2.w; }

// Pack/unpack Transform2D for vertex->fragment passing
// state_closed transforms have uniform scale and zero anchor
fn pack_transform(t: Transform2D) -> vec3f {
  return vec3f(t.pos.x, t.pos.y, t.angle);
}

fn unpack_transform(v: vec3f) -> Transform2D {
  return Transform2D(v.xy, v.z, vec2f(1.0), vec2f(0.0));
}



@vertex
fn vs_sceneW(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
  var pos = array(
    vec2f(-1.0, -1.0),
    vec2f(-1.0, 3.0),
    vec2f(3.0, -1.0),
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

  // Calculate anti-aliasing width. This is approx. 1 pixel wide
  // in world-space units. We use the main screen resolution for this.
  // (Using 1.5 for a slightly softer 1px blend)
  output.aaWidth = 1.5 / f32(pngine.canvasW);

// SYNC:

  let beat = pngine.time * BEAT_SECS;
  let bar = beat % 4.0;
  output.beat = vec2f(bar, beat);

  output.v_attr1 = vec4f(
      eyelid_bpm(beat),
      cam_bpm(beat),
      tangram_vis_bpm(beat),
      tangram_movement_bpm(beat)
  );

  output.v_attr2 = vec4f(
    cam_rot_bpm(beat), // cam_rot_t,
    bg_visibility_bpm(beat), // 1.0, // video_visibility_t
    pngine.time, // video_t
    bridge_visibility_bpm(beat) // bridge_visibility_t
  );

  // BRIDGE: packed into bridge_params (height1, height2, dist, train_mov)
  output.bridge_params = vec4f(
    bridge_height1_bpm(beat),
    bridge_height2_bpm(beat),
    bridge_dist_bpm(beat),
    train_bpm(beat)
  );

  // Background: packed into bg_params (glow_t, bg_vis_t)
  output.bg_params = vec2f(glow_bpm(beat), bg_visibility_bpm(beat));

  // Precompute tangram transforms (state_closed) in vertex shader
  output.t0 = pack_transform(state_closed[0]);
  output.t1 = pack_transform(state_closed[1]);
  output.t2 = pack_transform(state_closed[2]);
  output.t3 = pack_transform(state_closed[3]);
  output.t4 = pack_transform(state_closed[4]);
  output.t5 = pack_transform(state_closed[5]);
  output.t6 = pack_transform(state_closed[6]);

  return output;
}

const TRAIN_MOV_START = bridgeStart + 1.0;
fn train_bpm(beat: f32) -> f32 {
  let compass = 4.0; // 1 compass = 4 beats

  let start = TRAIN_MOV_START;
  let t1 = smoothstep(0.0, 1.0, progress(beat, compass * start, compass * (start + 5.0)));

  // -- Composition --
  var value = mix(0.0, 1.0, t1);

  return value;
}

fn bg_visibility_bpm(beat: f32) -> f32 {
  let compass = 4.0; // 1 compass = 4 beats

  let start1 = offTime;
  // 1. 
  let param1 = progress(beat, compass * start1, compass * (start1 + 1.0));
  let t1 = (sin(param1 * PI - PI * 0.5) + 1.0) / 2.0;

  // -- Composition --
  // Start at 0.0. (go from 0 to 1)
  var value = mix(0.0, 1.0, t1);

  return value;
}

const offTime = TRAIN_MOV_START + 3.5;
const bridgeStart = tangramMovement1 + 1.0;
fn bridge_visibility_bpm(beat: f32) -> f32 {
  let compass = 4.0; // 1 compass = 4 beats

  let start1 = bridgeStart;
  // 1. 
  let param1 = progress(beat, compass * start1, compass * (start1 + 1.0));
  let t1 = (sin(param1 * PI - PI * 0.5) + 1.0) / 2.0;

  // -- Composition --
  // Start at 0.0. (go from 0 to 1)
  var value = mix(0.0, 1.0, t1);

  let start2 = offTime;
  let param2 = progress(beat, compass * start2, compass * (start2 + 1.0));
  let t2 = (sin(param2 * PI - PI * 0.5) + 1.0) / 2.0;
  value = mix(value, 0.0, t2);

  return value;
}

const tangramStart = 5.0;
const tangramMovement1 = tangramStart + 1.0;
const tangramMovement2 = tangramMovement1 + 2.0;
const tangramMovement3 = tangramMovement2 + 3.0;

fn tangram_movement_bpm(beat: f32) -> f32 {
  let compass = 4.0; // 1 compass = 4 beats

  // 1. 
  let start1 = tangramMovement1;
  let param1 = progress(beat, compass * start1, compass * (start1 + 1.0));
  let t1 = (sin(param1 * PI - PI * 0.5) + 1.0) / 2.0;

  // 2. 
  let start2 = tangramMovement2;
  let param2 = progress(beat, compass * start2, compass * (start2 + 1.0));
  let t2 = (sin(param2 * PI - PI * 0.5) + 1.0) / 2.0;

  // 3. 
  let start3 = tangramMovement3;
  let param3 = progress(beat, compass * start3, compass * (start3 + 1.0));
  let t3 = (sin(param3 * PI - PI * 0.5) + 1.0) / 2.0;

  // -- Composition --
  // Start at 0.0. (go from 0 to 1)
  var value = mix(0.0, 0.333, t1);

  // Apply second movement: mix from result to 1.0 based on t2
  value = mix(value, 0.667, t2);

  // Apply second movement: mix from result to 1.0 based on t2
  value = mix(value, 0.78, t3);

  return value;
}


fn bridge_dist_bpm(beat:f32) -> f32 {
  let phase = floor(beat / 4.0) % 4.0;

  // Shared Constants
  let H1 = 0.3;
  let H2 = 0.7;
  let H3 = 0.4;
  let H4 = 0.5;

  var value: f32;

  switch u32(phase) {
      case 0u: {
          let b1 = vec4f(H1, 2.0, 0.0, 0.0);
          let b2 = vec4f(H2, 2.0, 0.0, 0.0);
          let b3 = vec4f(H3, 2.0, 0.0, 0.0);
          let b4 = vec4f(H4, 2.0, 0.0, 0.0);

          value = bar4(beat * 2.0, b1, b2, b3, b4);
      }
      default: {
        let b1 = vec4f(H1, 2.0, 0.0, 0.0);
        let b2 = vec4f(H1, 2.0, 0.0, 0.0);
        let b3 = vec4f(H1, 2.0, 0.0, 0.0);
        let b4 = vec4f(H1, 2.0, 0.0, 0.0);

        value = bar4(beat * 2.0, b1, b2, b3, b4);
      }
  }


  return value;
}

fn bridge_height1_bpm(beat:f32) -> f32 {
  // Shared Constants
  let H1 = 0.3;
  let H2 = 0.7;
  let H3 = 0.4;
  let H4 = 0.5;
  let phase = floor(beat / 4.0) % 4.0;

  var value: f32;

  switch u32(phase) {
      case 0u: {
          let b1 = vec4f(H1, 2.0, 0.0, 0.0);
          let b2 = vec4f(H2, 2.0, 0.0, 0.0);
          let b3 = vec4f(H3, 2.0, 0.0, 0.0);
          let b4 = vec4f(H4, 2.0, 0.0, 0.0);

          value = bar4(beat * 2.0, b1, b2, b3, b4);
      }
      default: {
        let b1 = vec4f(H1, 2.0, 0.0, 0.0);
        let b2 = vec4f(H3, 2.0, 0.0, 0.0);
        let b3 = vec4f(H4, 2.0, 0.0, 0.0);
        let b4 = vec4f(H2, 2.0, 0.0, 0.0);

        value = bar4(beat * 2.0, b1, b2, b3, b4);
      }
  }


  return value;
}

fn bridge_height2_bpm(beat:f32) -> f32 {
  // Shared Constants
  let H1 = 0.5;
  let H2 = 0.2;
  let H3 = 0.48;
  let H4 = 0.666;
  let phase = floor(beat / 4.0) % 4.0;

  var value: f32;

  switch u32(phase) {
      case 0u: {
          let b1 = vec4f(H1, 2.0, 0.0, 0.0);
          let b2 = vec4f(H2, 2.0, 0.0, 0.0);
          let b3 = vec4f(H3, 2.0, 0.0, 0.0);
          let b4 = vec4f(H4, 2.0, 0.0, 0.0);

          value = bar4(beat * 2.0, b1, b2, b3, b4);
      }
      default: {
        let b1 = vec4f(H1, 2.0, 0.0, 0.0);
        let b2 = vec4f(H3, 2.0, 0.0, 0.0);
        let b3 = vec4f(H1, 2.0, 0.0, 0.0);
        let b4 = vec4f(H4, 2.0, 0.0, 0.0);

        value = bar4(beat * 2.0, b1, b2, b3, b4);
      }
  }


  return value;
}

fn cam_rot_bpm(beat:f32) -> f32 {
  let phase = floor(beat / 4.0); //  % 4.0;

  // Shared Constants
  let OPEN = 0.0;
  let CLOSED = 1.0;
  let BEAT = 10.0;

  var glow_value: f32;

  let b1 = vec4f(OPEN, 2.0, 0.0, 0.0);
  let b2 = vec4f(CLOSED, 2.0, 0.0, 0.0);
  let b3 = vec4f(OPEN, 2.0, 0.0, 0.0);
  let b4 = vec4f(CLOSED, 2.0, 0.0, 0.0);

  glow_value = bar4(beat * 2.0, b1, b2, b3, b4);

  return glow_value;
}
fn glow_bpm(beat:f32) -> f32 {
  let phase = floor(beat / 4.0); //  % 4.0;

  // Shared Constants
  let OPEN = 0.0;
  let CLOSED = 1.0;

  var glow_value: f32;

  let b1 = vec4f(OPEN, 2.0, 0.0, 0.0);
  let b2 = vec4f(CLOSED, 2.0, 0.0, 0.0);
  let b3 = vec4f(OPEN, 2.0, 0.0, 0.0);
  let b4 = vec4f(CLOSED, 2.0, 0.0, 0.0);

  glow_value = bar4(beat * 2.0, b1, b2, b3, b4);

  return glow_value;
}

fn tangram_vis_bpm(beat: f32) -> f32 {
  let compass = 4.0; // 1 compass = 4 beats

  // 1. Calculate the progress for the first move (Compass 2: beats 4 to 8)
  // We use Smoothstep here to make the camera start and stop gently
  let start = 5.0;
  let t1 = smoothstep(0.0, 1.0, progress(beat, compass * start, compass * (start + 1.0)));

  // 2. Calculate the progress for the second move (Compass 4: beats 12 to 16)
  // let t2 = smoothstep(0.0, 1.0, progress(beat, compass * 300.0, compass * 301.0));

  // -- Composition --
  // Start at 0.0. (go from 0 to 1)
  var value = mix(0.0, 1.0, t1);

  let start2 = offTime;
  let param2 = progress(beat, compass * start2, compass * (start2 + 1.0));
  let t2 = (sin(param2 * PI - PI * 0.5) + 1.0) / 2.0;
  value = mix(value, 0.0, t2);
  // Apply second movement: mix from result to 1.0 based on t2
  // value = mix(1.0, 0.0, t2);

  return value;
}

fn cam_bpm(beat: f32) -> f32 {
  // -- Helper variables for readability --
  let compass = 4.0; // 1 compass = 4 beats

  // 1. Calculate the progress for the first move (Compass 2: beats 4 to 8)
  // We use Smoothstep here to make the camera start and stop gently
  let t1 = smoothstep(0.0, 1.0, progress(beat, compass * 1.0, compass * 2.0));

  // 2. Calculate the progress for the second move (Compass 4: beats 12 to 16)
  let t2 = smoothstep(0.0, 1.0, progress(beat, compass * 3.0, compass * 4.0));

  // -- Composition --

  // Start at 0.0.
  // Apply first movement: mix to 0.2 based on t1
  var cam_val = mix(0.0, 0.2, t1);

  // Apply second movement: mix from result to 1.0 based on t2
  cam_val = mix(cam_val, 1.0, t2);

  return cam_val;
}

fn eyelid_bpm(beat: f32) -> f32 {
  let phase = floor(beat / 4.0) % 4.0;

  // Shared Constants
  let OPEN = 0.0;
  let CLOSED = 1.0;

  var eye_value: f32;

  switch u32(phase) {
      case 0u: {
        let b1 = vec4f(OPEN, 2.0, 0.0, 0.0);
        let b2 = vec4f(CLOSED, 2.0, 0.0, 0.0);
        let b3 = vec4f(OPEN, 2.0, 0.0, 0.0);
        let b4 = vec4f(OPEN, 2.0, 0.0, 0.0);

        eye_value = bar4(beat, b1, b2, b3, b4);
      }
      case 2u: {
        let b1 = vec4f(OPEN, 2.0, 0.0, 0.0);
        let b2 = vec4f(CLOSED, 2.0, 0.0, 0.0);
        let b3 = vec4f(OPEN, 2.0, 0.0, 0.0);
        let b4 = vec4f(CLOSED, 2.0, 0.0, 0.0);

        eye_value = bar4(beat, b1, b2, b3, b4);
      }
      default: {
        let fast_beat = beat * 2.0;

        let b1 = vec4f(OPEN, 2.0, 0.0, 0.0);   
        let b2 = vec4f(OPEN, 2.0, 0.0, 0.0); 
        let b3 = vec4f(OPEN, 2.0, 0.0, 0.0);
        let b4 = vec4f(OPEN, 2.0, 0.0, 0.0);

        eye_value = bar4(fast_beat, b1, b2, b3, b4);
      }
  }

  return eye_value;
}


// ==========================================
// CONSTANTS & DATA
// ==========================================

const CAM_ROT_MAX_ANGLE = 0.01;

struct SDFResult {
  dist: f32,
  color: vec3f,
}


// The tangram square movement, rotating and anchor adjustment:
fn tangramTransform(initX: f32, fsInput: VertexOutput) -> Transform2D {
    let left = -0.5 * pngine.canvasRatio;
    let box_scene_pos_x = initX + (BOX_SIZE.x * 2.0) * 3.0; // left + BOX_SIZE.x * 4.0;

    const movements: u32 = 3;
    let animT = get_tangram_movement_t(fsInput) * f32(movements);
    let index: u32 = u32(floor(animT)); // u32(floor(round((1.0 + sin(0.5 * time.elapsed)) / 2.0)));
    let tangramScale = 0.20;
    let position = array<vec2<f32>, movements>(
        vec2f(box_scene_pos_x, 0.0) + vec2f(0.0, 1.0)*tangramScale,
        vec2f(box_scene_pos_x - BOX_SIZE.x * 2.0, 0.0) + vec2f(0.0, 1.0)*tangramScale,
        vec2f(box_scene_pos_x - BOX_SIZE.x * 3.0, 0.0) + vec2f(-1.0, 1.0)*tangramScale
    )[index];
    // x is inverted (left is 1.0, and right -1.0, so its from 1.0 to -1.0)
    let anchor = array<vec2<f32>, movements>(
        vec2f(1.0, -1.0) * tangramScale,
        vec2f(1.0, 1.0) * tangramScale,
        vec2f(-1.0, 1.0) * tangramScale,
    )[index];
    let startingAngle = array<f32, movements>(
        0.0,
        -PI * 0.5,
        -PI,
    )[index];
    let endingAngle = array<f32, movements>(-PI * 0.5, -PI, -PI * 1.5)[index];

    let tangramTransf = Transform2D(
        position,
        mix(startingAngle, endingAngle, fract(animT)),
        vec2f(tangramScale),
        anchor
    );

    return tangramTransf;
}

// Helper function to sample video
fn sampleVideo(uv: vec2f) -> vec4f {
  return textureSampleBaseClampToEdge(videoTexture, videoSampler, uv);
}

const VIDEO_RATIO: f32 = 1033.0 / 919.0; // w / h

fn scene_sdf_io(fsInput: VertexOutput, p: vec2f, transform: Transform2D) -> SDFResult {
  let q = transform_to_local(p, transform);
  let left = -1.0 * pngine.canvasRatio;
  let right = 1.0 * pngine.canvasRatio;

  var result = SDFResult(AWAY, vec3f(0.0));


  // Render box layers:
  let boxX = mix(0, left + BOX_SIZE.x * 3.0, get_cam_t(fsInput));
  let boxTransfInit = Transform2D(vec2f(boxX, 0.0), 0.0, vec2f(1.0), vec2f(0.0));
  let boxTransfFinal = Transform2D(vec2f(0.0, -0.3), 2*PI, vec2f(1.78), vec2f(0.0));
  var boxTransf = mixTransform(boxTransfInit, boxTransfFinal, fsInput.bg_params.y); 
  var video_color = vec3f();
  var box_pieces_color = vec3f();

  for (var i = 0u; i < BoxLayersLength; i++) {
    let layer_dist = box_layer_sdf(q, BoxLayers[i], boxTransf, get_eyelid_t(fsInput));

    if (layer_dist < result.dist) {
      result.dist = layer_dist;
      box_pieces_color = BoxLayers[i].color;

      if (get_video_t(fsInput) > 0.0) {
        let boxLocal = transform_to_local(q, boxTransf);
        var videoUV = (boxLocal / BOX_SIZE) * 0.66 + 0.66;
        videoUV.x -= 0.16;
        videoUV.y += 0.02;
        video_color = sampleVideo(videoUV).xyz;
      }
    }
  }
  result.color = mix(box_pieces_color, video_color, get_video_visibility_t(fsInput));

  // Render tangram box:
  if (get_tangram_visibility_t(fsInput) > 0.0) {
    let tangramQ = transform_to_local(q, tangramTransform(boxX, fsInput));

    // Use precomputed transforms from vertex shader (avoids array indexing in loop)
    let transforms = array<Transform2D, 7>(
      unpack_transform(fsInput.t0),
      unpack_transform(fsInput.t1),
      unpack_transform(fsInput.t2),
      unpack_transform(fsInput.t3),
      unpack_transform(fsInput.t4),
      unpack_transform(fsInput.t5),
      unpack_transform(fsInput.t6)
    );

    for (var i = 0u; i < 7u; i++) {
      // 'q' is the coordinate in the *main tangram's* local space.
      // This is the correct coordinate to pass to the piece SDF.
      let piece_dist = tangramPieceSDF(tangramQ, pieces[i], transforms[i]);

      // 'piece_dist' is already scaled by the piece's transform.
      // Now we scale it *again* by the main tangram's transform.
      let d = scale_sdf_distance(piece_dist, transform);

      if (d < result.dist) {
          // Tangram visibility:
          result.dist = mix(result.dist, d, get_tangram_visibility_t(fsInput)); // (sin(pngine.time) + 1.0) / 2.0);
          result.color = pieces[i].color;
      }
    }
  } 

  // Ground
  let d = segment(q, vec2f(left * 2.0, BOX_SIZE.y + 0.01), vec2f(right * 2.0, 0.0 + BOX_SIZE.y+ 0.01), 0.01);
  if (d < result.dist) {
    result.dist = d;
    result.color = vec3f(0.4, 0.2, 0.0);
  }

  // const bridgeScale = 1.0;
  // const transformBridge = Transform2D(vec2f(0.0, -0.2), 0.0, vec2f(bridgeScale, -bridgeScale), vec2f(0.0));
  // result = renderBridge(fsInput, q, transformBridge, result);

  return result;
  // let d = scale_sdf_distance(box(q, vec2f(0.3535)), transform);
}

fn render(fsInput: VertexOutput, time: f32, transform: Transform2D) -> vec3f {
    let uv = fsInput.uv;
    let correctedUv = fsInput.correctedUv;

    let sdf = scene_sdf_io(fsInput, correctedUv, transform);
    let d = sdf.dist;

    var color: vec3f;
    if (d > 0.0) {
        color = mix(vec3f(0.0), background(correctedUv, time, fsInput), get_cam_t(fsInput));
    } else {
        color = sdf.color;
    }

    // Render bridge as overlay with alpha blending
    if (get_bridge_visibility_t(fsInput) > 0.0) {
        let bridgeTransform = Transform2D(vec2f(), 0.0, vec2f(1.0, -1.0), vec2f());
        let q = transform_to_local(correctedUv, transform);
        let bridgeResult = renderBridge(fsInput, q, bridgeTransform, SDFResult());
        if (bridgeResult.dist < 0.0) {
            // Blend bridge color over existing color based on visibility
            color = mix(color, bridgeResult.color, get_bridge_visibility_t(fsInput));
        }
    }

    return color;
}

fn background(p: vec2f, t: f32, fsInput: VertexOutput) -> vec3f {
    // 1. Transform Coordinates
    let uv = transform_to_local(p, Transform2D(vec2f(), -CAM_ROT_MAX_ANGLE * get_cam_rot_t(fsInput), vec2f(1.0), vec2f()));

    // 2. Define Base Colors (High-Key / Bright)
    let bg_col = vec3f(0.96, 0.96, 0.99); // Almost white sky
    let floor_col = vec3f(0.85, 0.92, 0.88); // Mint floor

    // 3. Grid Calculation
    let grid_scale = 10.0;

    // Calculate grid lines (0.0 = background, 1.0 = line)
    // We use smoothstep for anti-aliased, crisp lines
    let gx = abs(sin(uv.x * grid_scale));
    let gy = abs(sin(uv.y * grid_scale));
    let line_width = 0.05;
    let grid_mask = smoothstep(line_width, 0.0, gx) + smoothstep(line_width, 0.0, gy);
    // Fade out grid as bridge appears
    let grid_fade = 1.0 - get_bridge_visibility_t(fsInput);
    let is_line = clamp(grid_mask, 0.0, 1.0) * grid_fade;

    // 4. Wave Glow Logic
    // Create a diagonal wave moving across the screen
    // sin(x + y - t) creates diagonal movement
    let wave_speed = 3.0;
    let wave_freq = 1.5;
    let wave_val = sin((uv.x + uv.y) * wave_freq - t * wave_speed);
    
    // Sharpen the wave so it looks like a "pulse" of light passing through
    let pulse = smoothstep(0.5, 1.0, wave_val);

    // 5. Line Color Logic
    // State A: Pure Black (High Contrast)
    let line_base = vec3f(0.0, 0.0, 0.0);
    
    // State B: Neon Cyan Glow (Bright & Cool)
    // We add 1.5 to make it "super bright" (bloom-like if supported, or just max saturated)
    let line_glow = vec3f(0.2, 1.0, 1.0) * 1.5; 
    
    // Mix the static black line with the glowing wave
    // We multiply by inputs.line_glow_t to control the overall effect strength
    // let glow_t = inputs.line_glow_t;
    let glow_t = fsInput.bg_params.x;
    let current_line_col = mix(line_base, line_glow, pulse * glow_t);

    // 6. Apply Grid to Background
    var final_col = mix(bg_col, current_line_col, is_line);

    // 7. The Floor (Overlay)
    let deckY = -1.0 + 0.05 * 2.0 + baseH * 2.0 + crossHeight * 2.0;
    if (-uv.y < deckY) {
        final_col = floor_col;
        
        // Optional: Fainter grid on the floor
        let floor_line_col = mix(vec3f(0.5, 0.6, 0.55), line_glow, pulse * glow_t);
        final_col = mix(final_col, floor_line_col, is_line * 0.5); // 50% opacity grid on floor
        
        // Horizon line
        // 
        let dist_from_top = abs((1.0 - uv.y) - deckY);
        if (dist_from_top < 0.02) {
            final_col = vec3f(0.6, 0.7, 0.65); 
        }
    }

    return mix(final_col, vec3f(0.9, 0.8, 0.7), fsInput.bg_params.y);
}


// 1. Define a Struct to handle the 'out' parameter logic
struct BezierResult {
    dist: f32,    // The signed distance
    point: vec2f  // The 'outQ' closest point on the curve
}

// 2. Helper functions required by the math
fn dot2(v: vec2f) -> f32 {
    return dot(v, v);
}

fn cro(a: vec2f, b: vec2f) -> f32 {
    return a.x * b.y - a.y * b.x;
}

// 3. The Main Function
fn bezier(pos: vec2f, A: vec2f, B: vec2f, C: vec2f) -> BezierResult {
    let a = B - A;
    let b = A - 2.0 * B + C;
    let c = a * 2.0;
    let d = A - pos;

    // Cubic equation setup
    let kk = 1.0 / dot(b, b);
    let kx = kk * dot(a, b);
    let ky = kk * (2.0 * dot(a, a) + dot(d, b)) / 3.0;
    let kz = kk * dot(d, a);

    var res = 0.0;
    var sgn = 0.0;
    var outQ = vec2f(0.0);

    let p = ky - kx * kx;
    let q = kx * (2.0 * kx * kx - 3.0 * ky) + kz;
    let p3 = p * p * p;
    let q2 = q * q;
    var h = q2 + 4.0 * p3;

    if (h >= 0.0) {
        // --- 1 Root Case ---
        h = sqrt(h);
        
        // copysign logic: (q < 0.0) ? h : -h
        // WGSL select is (false_val, true_val, cond)
        h = select(-h, h, q < 0.0); 
        
        let x = (h - q) / 2.0;
        let v = sign(x) * pow(abs(x), 1.0 / 3.0);
        var t = v - p / v;

        // Newton iteration to correct cancellation errors
        t -= (t * (t * t + 3.0 * p) + q) / (3.0 * t * t + 3.0 * p);
        
        t = clamp(t - kx, 0.0, 1.0);
        
        let w = d + (c + b * t) * t;
        outQ = w + pos;
        res = dot2(w);
        sgn = cro(c + 2.0 * b * t, w);
    } else {
        // --- 3 Roots Case ---
        let z = sqrt(-p);
        
        // Using standard Trig instead of custom cos_acos_3 approximation
        let v = acos(q / (p * z * 2.0)) / 3.0;
        let m = cos(v);
        let n = sin(v) * sqrt(3.0);
        
        let t = clamp(vec3f(m + m, -n - m, n - m) * z - kx, vec3f(0.0), vec3f(1.0));
        
        // Check candidate 1
        let qx = d + (c + b * t.x) * t.x;
        let dx = dot2(qx);
        let sx = cro(a + b * t.x, qx);
        
        // Check candidate 2
        let qy = d + (c + b * t.y) * t.y;
        let dy = dot2(qy);
        let sy = cro(a + b * t.y, qy);

        if (dx < dy) {
            res = dx;
            sgn = sx;
            outQ = qx + pos;
        } else {
            res = dy;
            sgn = sy;
            outQ = qy + pos;
        }
    }

    // Return the struct combining the point and the distance
    return BezierResult(sqrt(res) * sign(sgn), outQ);
}

const baseW = 0.2;
const baseH = 0.05;
const columnW = baseW / 8.66;
const columnH = 0.8;
const leftColumnX = -baseW / 1.5;
const rightColumnX = baseW / 1.5;
const crossHeight = 0.333 * 0.5;

fn renderCross(uv: vec2f, transform: Transform2D) -> f32 {
    let q = transform_to_local(uv, transform);
    let crossCol = vec3(0.0, 1.0, 1.0);
    let crossBar1Transf = Transform2D(vec2f(0.0, 0.0), PI * 0.25, vec2f(1.0), vec2f());
    let crossBar1P = transform_to_local(q, crossBar1Transf);
    let crossBar1D = box(crossBar1P, vec2f(columnW * 0.5, (rightColumnX - leftColumnX)*0.75));
    if (crossBar1D < 0.0) {
        return crossBar1D;
    }
    let crossBar2Transf = Transform2D(vec2f(0.0, 0.0), -PI * 0.25, vec2f(1.0), vec2f());
    let crossBar2P = transform_to_local(q, crossBar2Transf);
    let crossBar2D = box(crossBar2P, vec2f(columnW * 0.5, (rightColumnX - leftColumnX)*0.75));
    if (crossBar2D < 0.0) {
        return crossBar2D;
    }
    // Render CrossCircle
    let crossCircle2Transf = Transform2D(vec2f(0.0, 0.0), 0.0, vec2f(1.0), vec2f());
    let crossCircle2P = transform_to_local(q, crossCircle2Transf);
    let crossCircle2D = circle(crossCircle2P, vec2f(), columnW*1.5);
    if (crossCircle2D < 0.0) {
        return crossCircle2D;
    }

    return 1e10;
}

fn renderTrainWindow(q: vec2f, x: f32, y: f32) -> f32 {
    let windowsTransf = Transform2D(vec2f(x, y), 0.0, vec2f(1.0), vec2f());
    let windowsD = transformedBox(q, vec2f(0.02, 0.02), windowsTransf);
    return windowsD;
}

fn renderTrain(uv: vec2f, transform: Transform2D) -> SDFResult {
    let q = transform_to_local(uv, transform);
    var result = SDFResult(1e10, vec3f(0.0));
    
    // Train colors (matching reference)
    let bodyCol = vec3<f32>(0.122, 0.322, 0.518) * 1.5;     // yellow/gold body
    let windowCol = vec3f(0.95, 0.95, 0.9);   // cream/white windows
    let windowFrameCol = vec3f(0.15, 0.15, 0.15); // dark window frames
    let undercarriageCol = vec3f(0.1, 0.1, 0.1);  // dark undercarriage
    
    // Train dimensions
    let bodyW = 0.4;
    let bodyH = 0.055;
    let bodyY = 0.0;
    

    let windowsY = 0.01;
    let windowsX = -0.2;
    let windowsMargin = 0.1;
    let windowsD = min(
        renderTrainWindow(q, windowsX, windowsY),
        min(renderTrainWindow(q, windowsX + windowsMargin * 1.0, windowsY),
        min(renderTrainWindow(q, windowsX + windowsMargin * 2.0, windowsY),
        min(renderTrainWindow(q, windowsX + windowsMargin * 3.0, windowsY),
        min(renderTrainWindow(q, windowsX + windowsMargin * 4.0, windowsY),
        renderTrainWindow(q, windowsX + windowsMargin * 5.0, windowsY))
        )))); 
    if (result.dist > windowsD && windowsD <= 0) {
        result.color = windowCol;
        result.dist = windowsD;
        return result;
    }

    let door1Transf = Transform2D(vec2f(-0.33, 0.0), 0.0, vec2f(1.0), vec2f());
    let door1D = transformedBox(q, vec2f(0.05 * 0.5, bodyH - 0.01), door1Transf);
    if (door1D <= 0) {
        result.color = windowCol;
        result.dist = door1D;
        return result;
    }
    let door2Transf = Transform2D(vec2f(-0.27, 0.0), 0.0, vec2f(1.0), vec2f());
    let door2D = transformedBox(q, vec2f(0.05 * 0.5, bodyH - 0.01), door2Transf);
    if (door2D <= 0) {
        result.color = windowCol;
        result.dist = door2D;
        return result;
    }
    
    let carriageTransf = Transform2D(vec2f(0.0, 0.0), 0.0, vec2f(1.0), vec2f());
    let carriageD = transformedBox(q, vec2f(bodyW, bodyH), carriageTransf) - 0.01;
    if (result.dist > carriageD) {
        result.color = bodyCol;
        result.dist = carriageD;
    }


    let noseTransf = Transform2D(vec2f(-0.39, -0.004), PI * 0.33, vec2f(1.0), vec2f());
    let noseD = transformedBox(q, vec2f(bodyH * 0.5, bodyH * 0.5), noseTransf) - 0.03;
    
    if (result.dist > noseD) {

        result.color = bodyCol;
        result.dist = noseD;
    
    }

    let noseWindowTransf = Transform2D(vec2f(-0.43, -0.01), 0.0, vec2f(1.0), vec2f());
    let noseWindowD = transformedTri(q, vec2f(0.0), vec2f(0.03, 0.05), vec2f(0.03, 0.0), noseWindowTransf) - 0.01;
    
    if (noseWindowD < 0.0) {
        result.color = windowCol;
        result.dist = noseWindowD;
    }


    return result;
}

fn renderColumn(uv: vec2f, transform: Transform2D, height: f32) -> SDFResult {
    let q = transform_to_local(uv, transform);
    
    var result = SDFResult(1e10, vec3f(0.0));

    let deckBridgeY = 0.256;
    let crossesAvailableHeight = height - deckBridgeY;
    let numberOfCrosses = u32(crossesAvailableHeight / crossHeight);

    // 1. Define Gradient Colors
    let gradBot = vec3f(0.2, 0.0, 0.4); // Deep Violet
    let gradTop = vec3f(1.0, 0.0, 0.6); // Hot Pink

    // 2. Calculate Gradient
    // 0.0 is bottom, 1.0 is top (scaled to the column height)
    let gradient_t = smoothstep(-0.5, height, q.y);
    let pillarColor = mix(gradBot, gradTop, gradient_t);

    // Neon Cyan for structural crosses
    let crossCol = vec3(0.0, 1.0, 1.0); 

    for (var i = 0u; i < numberOfCrosses; i++) {
        let cross1D = renderCross(q, Transform2D(vec2f(0.0, -0.21 + 0.333 * f32(i)), 0.0, vec2f(1.0), vec2f()));
        if (cross1D < 0.0) {
            result.dist = cross1D;
            result.color = crossCol;
        }
    } 

    // Render Crosses Bottom
    let cross4D = renderCross(q, Transform2D(vec2f(0.0, -0.71), 0.0, vec2f(1.0), vec2f()));
    if (cross4D < 0.0) {
        result.dist = cross4D;
        result.color = crossCol;
    }

    // Render Pillar Base
    let baseCol = vec3f(0.1, 0.1, 0.15); // Dark Metallic

    let baseTransf = Transform2D(vec2f(0.0, -1.0 + baseH), 0.0, vec2f(1.0), vec2f());
    let baseP = transform_to_local(q, baseTransf);
    let baseD = box(baseP, vec2f(baseW, baseH));
    if (baseD < 0.0) {
        result.dist = baseD;
        result.color = baseCol;
    }

    // Render Pillar Left Column
    const leftColumnY = -1.0 + columnH + baseH * 2.0;
    let leftColumnTransf = Transform2D(vec2f(leftColumnX, height), 0.0, vec2f(1.0), vec2f(0.0, -1.0 + baseH * 2.0));
    let leftColumnP = transform_to_local(q, leftColumnTransf);
    let leftColumnD = box(leftColumnP, vec2f(columnW, height));
    if (leftColumnD < 0.0) {
        result.dist = leftColumnD;
        result.color = pillarColor;
    }

    // Render Pillar Right Column
    let rightColumnTransf = Transform2D(vec2f(rightColumnX, height), 0.0, vec2f(1.0), vec2f(0.0, -1.0 + baseH * 2.0));
    let rightColumnP = transform_to_local(q, rightColumnTransf);
    let rightColumnD = box(rightColumnP, vec2f(columnW, height));
    if (rightColumnD < 0.0) {
        result.dist = rightColumnD;
        result.color = pillarColor;
    }

    // Render Top Cap
    // MATCH LOGIC: We use gradTop because the gradient smoothstep reaches 1.0 exactly at 'height'
    let topCol = gradTop; 
    
    let topTransf = Transform2D(vec2f(0.0, height * 2.0), 0.0, vec2f(1.0), vec2f(0.0, -1.0 + baseH));
    let topP = transform_to_local(q, topTransf);
    let topD = box(topP, vec2f((rightColumnX - leftColumnX) * 0.5, baseH * 0.5));
    if (topD < 0.0) {
        result.dist = topD;
        result.color = topCol;
    }

    return result;
}

fn renderBridge(custom: VertexOutput, uv: vec2f, transform: Transform2D, currentRes: SDFResult) -> SDFResult {
    let q = transform_to_local(uv, transform);
    var res = currentRes;

    // Early exit if bridge is fully invisible
    if (get_bridge_visibility_t(custom) <= 0.0) {
        return res;
    }

    let vis = get_bridge_visibility_t(custom);
    let glow = custom.bg_params.x;

    let column1Height = 0.333 + custom.bridge_params.x;
    let column2Height = 0.333 + custom.bridge_params.y;
    let columnDist = custom.bridge_params.z * 2.5;
    let column1X = columnDist * 0.5;
    let column2X = -column1X;

    let deckCol = vec3f(0.05, 0.05, 0.05); 
    let deckH = 0.05;
    let deckY = -1.0 + deckH * 2.0 + baseH * 2.0 + crossHeight * 2.0;

    // Arc parameters
    let arcThickness = 0.012;
    let arcRightY = -0.333 + custom.bridge_params.x * 2.0;
    let arcLeftY = -0.333 + custom.bridge_params.y * 2.0;
    let columnMargin = (rightColumnX - leftColumnX) * 0.5;

    let arcLeft = vec2f(column2X + baseW - columnW * 2.0, arcLeftY);
    let arcRight = vec2f(column1X - baseW + columnW * 2.0, arcRightY);
    let arcMid = vec2f(0.0, deckY);

    let leftArcStart = vec2f(column2X - columnMargin, arcLeftY);
    let rightArcStart = vec2f(column1X + columnMargin, arcRightY);
    let leftArcEnd = vec2f(-2.0, deckY + deckH);
    let leftArcMid = vec2f((leftArcStart.x + leftArcEnd.x) * 0.5, deckY);
    let rightArcEnd = vec2f(2.0, deckY + deckH);
    let rightArcMid = vec2f((rightArcStart.x + rightArcEnd.x) * 0.5, deckY);

    let cableThickness = 0.008;
    let cableSpacing = 0.15;
    let cableCol = vec3f(0.7, 0.75, 0.8); 

    // --- LAYER 1: CABLES ---
    // Center cables
    let spanWidth = arcRight.x - arcLeft.x;
    let numCables = i32(spanWidth / cableSpacing);
    for (var i = 1; i < numCables; i++) {
        let t = f32(i) / f32(numCables);
        let arcPointX = (1.0 - t) * (1.0 - t) * arcLeft.x + 2.0 * (1.0 - t) * t * arcMid.x + t * t * arcRight.x;
        let arcPointY = (1.0 - t) * (1.0 - t) * arcLeft.y + 2.0 * (1.0 - t) * t * arcMid.y + t * t * arcRight.y;
        let cableTop = arcPointY;
        let cableBottom = deckY + deckH;
        let cableHeight = (cableTop - cableBottom) * 0.5;
        let cableCenterY = (cableTop + cableBottom) * 0.5;
        let cableD = box(q - vec2f(arcPointX, cableCenterY), vec2f(cableThickness, cableHeight));
        if (cableD < 0.0) {
            res.dist = mix(res.dist, cableD, vis);
            res.color = cableCol;
        }
    }

    // Left cables
    let leftSpanWidth = leftArcStart.x - leftArcEnd.x;
    let numLeftCables = i32(leftSpanWidth / cableSpacing);
    for (var i = 1; i < numLeftCables; i++) {
        let t = f32(i) / f32(numLeftCables);
        let arcPointX = (1.0 - t) * (1.0 - t) * leftArcStart.x + 2.0 * (1.0 - t) * t * leftArcMid.x + t * t * leftArcEnd.x;
        let arcPointY = (1.0 - t) * (1.0 - t) * leftArcStart.y + 2.0 * (1.0 - t) * t * leftArcMid.y + t * t * leftArcEnd.y;
        let cableTop = arcPointY;
        let cableBottom = deckY + deckH;
        if (cableTop > cableBottom) {
            let cableHeight = max((cableTop - cableBottom) * 0.5, 0.001);
            let cableCenterY = (cableTop + cableBottom) * 0.5;
            let cableD = box(q - vec2f(arcPointX, cableCenterY), vec2f(cableThickness, cableHeight));
            if (cableD < 0.0) {
                res.dist = mix(res.dist, cableD, vis);
                res.color = cableCol;
            }
        }
    }

    // Right cables
    let rightSpanWidth = rightArcEnd.x - rightArcStart.x;
    let numRightCables = i32(rightSpanWidth / cableSpacing);
    for (var i = 1; i < numRightCables; i++) {
        let t = f32(i) / f32(numRightCables);
        let arcPointX = (1.0 - t) * (1.0 - t) * rightArcStart.x + 2.0 * (1.0 - t) * t * rightArcMid.x + t * t * rightArcEnd.x;
        let arcPointY = (1.0 - t) * (1.0 - t) * rightArcStart.y + 2.0 * (1.0 - t) * t * rightArcMid.y + t * t * rightArcEnd.y;
        let cableTop = arcPointY;
        let cableBottom = deckY + deckH;
        if (cableTop > cableBottom) {
            let cableHeight = max((cableTop - cableBottom) * 0.5, 0.001);
            let cableCenterY = (cableTop + cableBottom) * 0.5;
            let cableD = box(q - vec2f(arcPointX, cableCenterY), vec2f(cableThickness, cableHeight));
            if (cableD < 0.0) {
                res.dist = mix(res.dist, cableD, vis);
                res.color = cableCol;
            }
        }
    }

    // --- LAYER 2: ARCS ---
    let arcColor = vec3f(0.6, 0.6, 0.65); 

    let centerArcD = abs(bezier(q, arcLeft, arcMid, arcRight).dist) - arcThickness;
    if (centerArcD < 0.0) {
        res.dist = mix(res.dist, centerArcD, vis);
        res.color = arcColor;
    }

    let leftArcD = abs(bezier(q, leftArcStart, leftArcMid, leftArcEnd).dist) - arcThickness;
    if (leftArcD < 0.0) {
        res.dist = mix(res.dist, leftArcD, vis);
        res.color = arcColor;
    }

    let rightArcD = abs(bezier(q, rightArcStart, rightArcMid, rightArcEnd).dist) - arcThickness;
    if (rightArcD < 0.0) {
        res.dist = mix(res.dist, rightArcD, vis);
        res.color = arcColor;
    }

    // --- LAYER 3: COLUMNS ---
    let column1Transf = Transform2D(vec2f(column1X, 0.0), 0.0, vec2f(1.0), vec2f());
    let columnResult1 = renderColumn(q, column1Transf, column1Height);
    if (columnResult1.dist < 0.0) {
        res.dist = mix(res.dist, columnResult1.dist, vis);
        res.color = columnResult1.color;
    }

    let column2Transf = Transform2D(vec2f(column2X, 0.0), 0.0, vec2f(1.0), vec2f());
    let columnResult2 = renderColumn(q, column2Transf, column2Height);
    if (columnResult2.dist < 0.0) {
        res.dist = mix(res.dist, columnResult2.dist, vis);
        res.color = columnResult2.color;
    }

    // --- LAYER 4: TRAINS ---
    let trainY = deckY + deckH + 0.018;
    let trainX = 2.5 - 6.0 * custom.bridge_params.w;

    let train1Transf = Transform2D(vec2f(trainX, trainY + 0.04), 0.0, vec2f(1.0), vec2f());
    let train1Result = renderTrain(q, train1Transf);
    if (train1Result.dist < 0.0) {
        res.dist = mix(res.dist, train1Result.dist, vis);
        res.color = train1Result.color;
    }

    let train2Transf = Transform2D(vec2f(trainX + 0.84, trainY + 0.04), 0.0, vec2f(-1.0, 1.0), vec2f());
    let train2Result = renderTrain(q, train2Transf);
    if (train2Result.dist < 0.0) {
        res.dist = mix(res.dist, train2Result.dist, vis);
        res.color = train2Result.color;
    }

    // --- LAYER 5: DECK ---
    let deckTransf = Transform2D(vec2f(0.0, deckY), 0.0, vec2f(1.0), vec2f());
    let deckD = transformedBox(q, vec2f(2.0, deckH), deckTransf);
    if (deckD < 0.0) {
        res.dist = mix(res.dist, deckD, vis);
        res.color = deckCol;
    }

    // --- LAYER 6: DECK CIRCLES ---
    let circleRadiusBase = deckH * 0.5;
    let circleSpacing = 0.12;
    let circleCol = vec3f(0.0, 0.8, 0.8);
    
    let cellIndex = round(q.x / circleSpacing);
    let qx_repeated = q.x - circleSpacing * cellIndex;
    let circleCenter = vec2f(0.0, deckY);
    let circleD = circle(vec2f(qx_repeated, q.y), circleCenter, circleRadiusBase);
    if (circleD < 0.0) {
        res.dist = mix(res.dist, circleD, vis);
        res.color = circleCol;
    }

    return res;
}

@fragment
fn fs_sceneW(fsInput: VertexOutput) -> @location(0) vec4f {
  let t = pngine.time;
  
  let eyelid_t = inputs.eyelid_t;
  let cam_t = inputs.cam_t;
  let tangram_visibility_t = inputs.tangram_visibility_t;
  let tangram_movement_t = inputs.tangram_movement_t;
  let cam_rot_t = inputs.cam_rot_t;
  let video_visibility_t = inputs.video_visibility_t;
  let video_t = inputs.video_t;

  let cam = get_cam_t(fsInput);
  let left = -0.5 * pngine.canvasRatio;
  let box_scene_pos_x = mix(0, left + BOX_SIZE.x * 2.0, cam);

  var sceneTransform: Transform2D;
  // boxTransform.pos = vec2f(0.0, 0.0);
  sceneTransform.pos = vec2f(mix(0.0, 0.0, cam), 0.0);
  sceneTransform.anchor = vec2f(mix(2.0, 0.0, cam), mix(0.0, 0.2, cam));
  sceneTransform.angle = -CAM_ROT_MAX_ANGLE * get_cam_rot_t(fsInput); // PI * 0.25;
  // boxTransform.scale = vec2f(2.25);
  sceneTransform.scale = vec2f(mix(5.25, 1.0, cam));
  var color = render(fsInput, t, sceneTransform);

  color = pow(color, vec3f(2.2));

  return vec4f(color, 1.0);
}
