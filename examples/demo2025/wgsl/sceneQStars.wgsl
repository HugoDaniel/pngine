

struct StarParticle {
  pos : vec4f,
  vel : vec4f,
}
struct SceneQInputs {
  shape_attraction: f32,
  shape_morph: f32,  // 0 = square, 1 = cat face
}
struct StarsSimParams {
  deltaT: f32,
  simId: f32,
  rule1Distance: f32,
  rule2Distance: f32,
  rule3Distance: f32,
  rule1Scale: f32,
  rule2Scale: f32,
  rule3Scale: f32,
}

struct StarsParticles {
  particles : array<StarParticle>,
}

fn sdfSquare(uv: vec2f) -> f32 {
  return box(uv, vec2f(3.5));
}

fn sdfCat(uv: vec2f) -> f32 {
  return catFaceLogo(uv, 5.0, 0.0, Transform2D(vec2f(), 0.0, vec2f(10.0), vec2f()));
}

// Blend between square and cat based on morph value (0 = square, 1 = cat)
fn sdf(uv: vec2f, morph: f32) -> f32 {
  let squareDist = sdfSquare(uv);
  let catDist = sdfCat(uv);
  return catDist; // mix(squareDist, catDist, clamp(morph, 0.0, 1.0));
}

const SDF_EPSILON: f32 = 0.0001;

fn sdfGradient(pos: vec2f, morph: f32) -> vec2f {
  let e = vec2f(SDF_EPSILON, 0.0);
  let dx = sdf(pos + e.xy, morph) - sdf(pos - e.xy, morph);
  let dy = sdf(pos + e.yx, morph) - sdf(pos - e.yx, morph);
  return normalize(vec2f(dx, dy) / (2.0 * SDF_EPSILON));
}

struct PngineInputs {
  time: f32,
  canvasW: f32,
  canvasH: f32,
  canvasRatio: f32,
};

@binding(0) @group(0) var<storage, read> particlesA : StarsParticles;
@binding(1) @group(0) var<storage, read_write> particlesB : StarsParticles;
@binding(2) @group(0) var<uniform> params : StarsSimParams;
@binding(3) @group(0) var<uniform> inputs : SceneQInputs;
@binding(4) @group(0) var<uniform> pngine: PngineInputs;

// BPM-synced shape attraction (must match sceneQ.wgsl)
const SCENE_Q_START_BPM: f32 = 0.0;  // Start immediately
const shapeAttractionStart: f32 = SCENE_Q_START_BPM;
const shapeAttractionEnd: f32 = shapeAttractionStart + 3.0;  // 3 compasses to form

fn shape_attraction_bpm(beat: f32) -> f32 {
  let compass = 4.0; // 1 compass = 4 beats

  // Ramp up attraction from beat 0 to beat 4 (first compass)
  let t1 = smoothstep(0.0, 1.0, progress(beat, 0.0, compass * 1.0));
  var value = t1;

  // Hold at full strength until compass 3, then fade out
  let start2 = shapeAttractionEnd;
  let param2 = progress(beat, compass * start2, compass * (start2 + 1.0));
  let t2 = (sin(param2 * PI - PI * 0.5) + 1.0) / 2.0;
  value = mix(value, 0.0, t2);

  return value;
}

fn deltaT_bpm(beat: f32) -> f32 {
  // Smooth and slow: gentle sine wave modulation
  let base = 0.5;
  let variation = 0.1;
  let smooth_wave = sin(beat * 0.5) * 0.5 + 0.5; // Slow oscillation
  return base + variation * smooth_wave;
}

@compute @workgroup_size(64)
fn computeStarsParticlesMain(@builtin(global_invocation_id) GlobalInvocationID : vec3u) {
  var index = GlobalInvocationID.x;
  let beat = pngine.time * BEAT_SECS;
  // Use the simulation deltaT parameter, not total elapsed time
  let deltaT = params.deltaT;
  
  var vPos = particlesA.particles[index].pos;
  var vVel = particlesA.particles[index].vel;

  // shape_attraction: how strongly particles are attracted to the shape (0 = none, 1 = full)
  // shape_morph: which shape to attract to (0 = square, 1 = cat face)
  // Use BPM-computed value instead of uniform buffer (which is just the slider)
  let shape_attraction = shape_attraction_bpm(beat);
  let shape_morph = inputs.shape_morph;

  // Store original position in vel.w from initialization
  var originalX = vVel.w;

  // Z movement - slow down when forming shape so stars stay visible
  let z_speed = mix(1.0, 0.1, shape_attraction);  // Slow down as attraction increases
  vPos.z += vVel.z * deltaT * z_speed;

  // XY movement: attract toward shape boundary based on SDF
  if (shape_attraction > 0.001) {
    let currentSDF = sdf(vPos.xy, shape_morph);
    let grad = sdfGradient(vPos.xy, shape_morph);

    // Stronger attraction force - multiply by 20 instead of 5
    let attraction_strength = shape_attraction * deltaT * 20.0;

    if (currentSDF > 0.01) {
      // Outside: attract toward boundary
      let displacement = -grad * min(currentSDF, 2.0) * attraction_strength;
      vPos.x += displacement.x;
      vPos.y += displacement.y;
    } else if (currentSDF < -0.01) {
      // Inside: push back out to boundary
      let pushOut = -grad * currentSDF * deltaT * 5.0;
      vPos.x += pushOut.x;
      vPos.y += pushOut.y;
    }
  }
  
  // Wrap Z
  if (vPos.z < -10.0) { vPos.z = -9.0; }
  if (vPos.z > 4.0) { vPos.z = -10.0; }
  
  particlesB.particles[index].pos = vPos;
  particlesB.particles[index].vel = vVel;
}
