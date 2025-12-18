struct PngineInputs {
  time: f32,
  canvasW: f32,
  canvasH: f32,
  canvasRatio: f32,
};

struct SceneYInputs {
  twist: f32,
  viz: f32,
  fov: f32,
}

@group(0) @binding(0) var<uniform> pngine: PngineInputs;
@group(0) @binding(1) var<uniform> inputs: SceneYInputs;
@group(0) @binding(2) var catSdfTexture: texture_2d<f32>;
@group(0) @binding(3) var catSdfSampler: sampler;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
  @location(1) correctedUv: vec2f,

  @location(2) twist: f32,
  @location(3) viz: f32,
  @location(4) fov: f32,
  @location(5) tint: f32,
  @location(6) sin_twist_half: f32,
  @location(7) cos_twist: f32,
  @location(8) sin_twist: f32,
  @location(9) star_transition: f32,  // 0 = cats, 1 = stars (for smooth transition to sceneQ)
  @location(10) bg_pink: f32,         // 1 = full pink, 0 = normal (for transition from sceneT)
}

// NOTE: Vertex shader moved after helper functions (WGSL requires forward declarations)

// Scene timing
const SCENE_DURATION: f32 = 28.0;       // 7 compasses
const SCENE_END_DURATION: f32 = 4.0;    // 1 compass for fade out
const SCENE_END_START: f32 = SCENE_DURATION - SCENE_END_DURATION;  // beat 24

// twist: starts high and holds, then crescendo envelope (not beat-synced)
fn twist_bpm(beat: f32) -> f32 {
  let high_value = 0.8;

  // Hold immutable for 2 compasses (8 beats)
  if (beat < 9.0) {
    return high_value;
  }

  // After hold: smooth crescendo envelope
  let active_time = beat - 9.0;

  // Crescendo: slowly increasing amplitude over time
  let envelope = smoothstep(0.0, 32.0, active_time);  // ramps up over 32 beats

  // Smooth wave motion (not beat-synced, slower organic movement)
  let wave = sin(active_time * 0.3) * envelope * 0.3;

  // Gradual drift upward
  let drift = active_time * 0.01 * envelope;

  return high_value + wave + drift;
}

// fov: breathes with the music, kicks on strong beats
fn fov_bpm(beat: f32) -> f32 {
  // Base FOV
  let base = 1.0;

  // Gentle breathing
  let breathe = sin(beat * PI / 2.0) * 0.05;

  // Kick on strong beats (1 and 3)
  let bar_pos = beat % 4.0;
  let kick1 = smoothstep(0.0, 0.1, bar_pos) * (1.0 - smoothstep(0.1, 0.5, bar_pos)) * 0.15;
  let kick3 = smoothstep(2.0, 2.1, bar_pos) * (1.0 - smoothstep(2.1, 2.5, bar_pos)) * 0.1;

  return base + breathe - kick1 - kick3;
}

// viz: after intro, cycles between 0.0, 0.333, 0.666 on strong beats, returns to 1.0 at end
fn viz_bpm(beat: f32) -> f32 {
  // First compass: fade from 1.0 to base level
  if (beat < 4.0) {
    let progress = beat / 4.0;
    return mix(1.0, 0.0, smoothstep(0.0, 1.0, progress));
  }

  // Scene end: fade back to 1.0
  if (beat >= SCENE_END_START) {
    let end_progress = (beat - SCENE_END_START) / SCENE_END_DURATION;
    let current_viz = bar4(beat,
      vec4f(0.0, 2.0, 0.0, 0.0),
      vec4f(0.333, 2.0, 0.0, 0.0),
      vec4f(0.0, 2.0, 0.0, 0.0),
      vec4f(0.666, 2.0, 0.0, 0.0)
    );
    return mix(current_viz, 1.0, smoothstep(0.0, 1.0, end_progress));
  }

  // Main scene: step between values on strong beats
  let b1 = vec4f(0.0, 2.0, 0.0, 0.0);    // beat 1: low
  let b2 = vec4f(0.333, 2.0, 0.0, 0.0);  // beat 2: medium
  let b3 = vec4f(0.0, 2.0, 0.0, 0.0);    // beat 3: low
  let b4 = vec4f(0.666, 2.0, 0.0, 0.0);  // beat 4: high

  return bar4(beat, b1, b2, b3, b4);
}

// tint: starts at 1.0, holds for one compass (4 beats), then goes to 0.0 in one beat
fn tint_bpm(beat: f32) -> f32 {
  if (beat < 4.0) {
    return 1.0;  // hold at 1.0 for first compass
  }
  if (beat < 5.0) {
    // beat 4-5: transition from 1.0 to 0.0
    let t = beat - 4.0;
    return mix(1.0, 0.0, smoothstep(0.0, 1.0, t));
  }
  return 0.0;  // hold at 0.0 after
}

// star_transition: 0.0 until last beat, then ramps to 1.0 for smooth transition to sceneQ
fn star_transition_bpm(beat: f32) -> f32 {
  let transition_start = SCENE_DURATION - 1.0;  // last beat (beat 27)
  if (beat < transition_start) {
    return 0.0;
  }
  let t = (beat - transition_start) / 1.0;  // 1 beat transition
  return smoothstep(0.0, 1.0, t);
}

// bg_pink: starts at 1.0 (full pink), fades to 0.0 during first beat (transition from sceneT)
fn bg_pink_bpm(beat: f32) -> f32 {
  if (beat >= 1.0) {
    return 0.0;
  }
  return 1.0 - smoothstep(0.0, 1.0, beat);
}

struct SDFResult {
  dist: f32,
  color: vec3f,
}

// A palette function for nice gradients (iquilezles.org)
fn palette(t: f32) -> vec3f {
    let a = vec3f(0.5, 0.5, 0.5);
    let b = vec3f(0.5, 0.5, 0.5);
    let c = vec3f(1.0, 1.0, 1.0);
    let d = vec3f(0.263, 0.416, 0.557); // Iridescent colors
    return a + b * cos(6.28318 * (c * t + d));
}

fn hash3(p: vec3f) -> vec3f {
    var p_no_zero = p + vec3f(12.34, 56.78, 90.12); 
    var p3 = fract(p_no_zero * vec3f(0.1031, 0.1030, 0.0973));
    p3 = p3 + dot(p3, p3.yzx + 19.19);
    return fract(vec3f(p3.x + p3.y, p3.y + p3.z, p3.z + p3.x) * p3.zxy);
}

fn rot2D(a: f32) -> mat2x2<f32> {
    let s: f32 = sin(a);
    let c: f32 = cos(a);
    return mat2x2(c, -s, s, c);
}

fn sdSphere(p: vec3<f32>, r: f32) -> f32 {
  return length(p) - r;
}

fn opExtrusion(p: vec3f, sdf: f32, h: f32) -> f32 {
    // 1. Construct the 2D vector
    // w.x = The distance to the 2D shape boundaries
    // w.y = The distance to the top/bottom "lids" of the extrusion
    let w = vec2f(sdf, abs(p.z) - h);
    
    // 2. Interior + Exterior distance logic
    // specific note: max(w, vec2f(0.0))
    // WGSL built-ins like max() generally require both arguments 
    // to be the same type. We cannot pass '0.0' (scalar) against 
    // 'w' (vector) directly; we must construct a zero vector.
    
    return min(max(w.x, w.y), 0.0) + length(max(w, vec2f(0.0)));
}

// Get tangram drawing transform using switch (avoids slow nested array access)
fn get_tangram_drawing(shapeId: u32, pieceIndex: u32) -> Transform2D {
    switch shapeId {
        case 0u: { return state_cat1[pieceIndex]; }
        case 1u: { return state_cat2[pieceIndex]; }
        case 2u: { return state_cat3[pieceIndex]; }
        case 3u: { return state_cat4[pieceIndex]; }
        case 4u: { return state_cat5[pieceIndex]; }
        case 5u: { return state_cat6[pieceIndex]; }
        default: { return state_heart[pieceIndex]; }
    }
}

fn scene_sdf(uv: vec2f, transform: Transform2D, seed: f32) -> f32 {
    let q = transform_to_local(uv, transform);
    var result = SDFResult(1e10, vec3f(0.0));

    // Convert random value (0.0 to 1.0) to shape index (0 to 5)
    let maxShapes = 6u;
    let shapeId = min(u32(seed * f32(maxShapes)), maxShapes - 1u);

    for (var i = 0u; i < 7u; i++) {
        // Use switch-based lookup instead of nested array access
        let anim_transform = get_tangram_drawing(shapeId, i);

        let piece_dist = tangramPieceSDF(q, pieces[i], anim_transform);
        let d = scale_sdf_distance(piece_dist, transform);

        if (d < result.dist) {
            result.dist = d;
            // Early termination: if we're inside a piece, can't get smaller
            if (d < 0.001) { break; }
        }
    }
    return result.dist;
}

const GRID_SIZE: f32 = 8.0;
const EXTRUSION_HEIGHT: f32 = 0.08;

// Texture atlas layout: 3 columns x 2 rows = 6 cats
const TEX_COLS: f32 = 3.0;
const TEX_ROWS: f32 = 2.0;
const MAX_DIST: f32 = 3.0;  // Must match cat_sdf_texture.wgsl

// Shape scale - bigger cats, more visible
const SHAPE_SCALE: f32 = 0.2;

// Decode SDF from texture: 0.5 = surface, < 0.5 = inside, > 0.5 = outside
fn decode_sdf(encoded: f32) -> f32 {
    return (encoded - 0.5) * 2.0 * MAX_DIST;
}

// Sample cat SDF from baked texture - FAST! One texture lookup per cell
fn sample_cat_sdf(local_pos: vec2f, cat_index: u32) -> f32 {
    // Scale position - cat occupies small portion of cell (like original SDF_SCALE)
    // local_pos in [-0.5, 0.5], we want to sample center portion of texture
    let scaled_pos = local_pos / SHAPE_SCALE;  // Expand: small area maps to full texture

    // Map to UV [0, 1] - center of cell maps to center of texture
    let local_uv = scaled_pos * 0.5 + 0.5;

    // Clamp UV and compute distance from boundary for smooth falloff
    let clamped_uv = clamp(local_uv, vec2f(0.0), vec2f(1.0));
    let boundary_dist = length(max(abs(local_uv - 0.5) - 0.5, vec2f(0.0)));

    // Calculate tile position in atlas (3x2 grid)
    let tile_x = f32(cat_index % 3u);
    let tile_y = f32(cat_index / 3u);

    // Map to texture UV
    let tex_uv = vec2f(
        (tile_x + clamped_uv.x) / TEX_COLS,
        (tile_y + clamped_uv.y) / TEX_ROWS
    );

    // Sample, decode, and scale distance
    let encoded = textureSampleLevel(catSdfTexture, catSdfSampler, tex_uv, 0.0).r;
    let tex_dist = decode_sdf(encoded) * SHAPE_SCALE;

    // Add boundary distance for smooth SDF outside texture bounds
    return tex_dist + boundary_dist;
}

// Fast SDF using baked texture + analytical extrusion
fn sdf(p: vec3f, cat_index: u32, star_t: f32) -> f32 {
    // During star transition, shrink shapes by scaling position
    // star_t = 0: normal size, star_t = 1: tiny dots
    let shrink_factor = mix(1.0, 8.0, star_t);  // 8x smaller at full transition
    let p_scaled = vec3f(p.xy * shrink_factor, p.z);

    // Sample 2D SDF from texture
    let d2d = sample_cat_sdf(p_scaled.xy, cat_index);

    // Scale distance back and reduce extrusion height for stars
    let scaled_d2d = d2d / shrink_factor;
    let ext_height = mix(EXTRUSION_HEIGHT, 0.01, star_t);

    // Apply extrusion analytically (cheap)
    return opExtrusion(vec3f(p.xy, p.z), scaled_d2d, ext_height);
}

fn map(fsInput: VertexOutput, p_in: vec3<f32>) -> f32 {
    var p = p_in;

    // Space bending: twist world based on Z distance
    p = vec3f(p.xy * rot2D(p.z * 0.05 * fsInput.sin_twist_half), p.z);

    let cell_id = vec3<i32>(floor(p / GRID_SIZE));

    // Hash for random properties per cell
    let h = hash3(vec3f(f32(cell_id.x), f32(cell_id.y), f32(cell_id.z)) + 1337.0);

    // Pick cat shape based on cell hash (0-5 for 6 cats)
    let cat_index = u32(h.x * 6.0) % 6u;

    var q = (p / GRID_SIZE);
    q = fract(q) - 0.5;

    // Audio reactive jitter - reduced to stay within texture bounds
    let bounce_energy = (pow(sin(4.0 * pngine.time), 4.0) + 1.0) / 2.0;
    let audio_kick = fsInput.viz * 0.2;  // Reduced from 0.4

    let jitter = (h.yzx - vec3f(0.5)) * mix(0.05, 0.15 + audio_kick, bounce_energy);  // Reduced jitter
    let local = (vec3f(q) + jitter);

    let shape = sdf(local, cat_index, fsInput.star_transition);
    return shape * GRID_SIZE;
}

fn renderBalls(fsInput: VertexOutput, uv_i: vec2f) -> vec3f {
    // Camera rotation with twist
    // OPTIMIZATION: Use precomputed sin/cos from vertex shader instead of rot2D()
    let c = fsInput.cos_twist;
    let s = fsInput.sin_twist;
    let uv = vec2f(
        uv_i.x * c - uv_i.y * s,
        uv_i.x * s + uv_i.y * c
    );

    // Speed increases slightly with audio intensity
    let speed = 8.0; //  + (custom.viz * 10.0);

    // FOV kicks when audio hits (Zoom effect)
    let fov = fsInput.fov - (fsInput.viz * 0.2);

    let ro = vec3f(0, 0, -3 + pngine.time * speed);
    let rd = normalize(vec3f(uv * fov, 1.0));

    var t = 0.0;
    var col = vec3f(); // vec3<f32>(0.1, 0.8, 0.2) * (fsInput.viz);

    // Star color (matches sceneQ stars: vec3f(sin(t), cos(t), 1.0))
    let star_color = vec3f(sin(pngine.time), cos(pngine.time), 1.0);
    let star_t = fsInput.star_transition;

    // Raymarching loop - 64 iterations is enough for this grid
    for (var i: i32 = 0; i < 64; i++) {
        var p = ro + rd * t;
        var d = map(fsInput, p);

        // Palette glow based on Z-depth
        let depth_color = palette(p.z * 0.04 + pngine.time * 0.2);

        // Blend toward star color during transition
        let blended_color = mix(depth_color, star_color, star_t);

        // Audio boosts the glow density
        let density = 0.008 + (fsInput.viz * 0.01);
        let falloffSpeed = 8.0;

        col += blended_color * density * exp(-d * falloffSpeed);

        if (d < 0.001) {
            col += blended_color * 2.0;
            break;
        }

        // Step size: more conservative for texture-based SDF
        t += d * 0.4;
        if (t > 100.0) { break; }
    }

    return col;

}

fn render(fsInput: VertexOutput) -> vec3f {
  return renderBalls(fsInput, fsInput.correctedUv);
}

@vertex
fn vs_sceneY(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
  var pos = array(
    vec2f(-1.0, -1.0),
    vec2f(-1.0,  3.0),
    vec2f( 3.0, -1.0),
  );

  var output: VertexOutput;
  let xy = pos[vertexIndex];
  output.position = vec4f(xy, 0.0, 1.0);
  output.uv = xy * vec2f(0.5, -0.5) + vec2f(0.5);

  // Aspect-ratio correction
  var corrected = output.uv * 2.0 - 1.0;
  let minDim = min(pngine.canvasW, pngine.canvasH);
  let scale = vec2f(pngine.canvasW / minDim, pngine.canvasH / minDim);
  corrected *= scale;
  output.correctedUv = corrected;

  let beat = pngine.time * BEAT_SECS;

  output.twist = twist_bpm(beat);
  output.viz = viz_bpm(beat);
  output.fov = fov_bpm(beat);
  output.tint = tint_bpm(beat);
  output.star_transition = star_transition_bpm(beat);
  output.bg_pink = bg_pink_bpm(beat);

  // Precompute trig values
  output.sin_twist_half = sin(output.twist * 0.5);
  output.cos_twist = cos(output.twist);
  output.sin_twist = sin(output.twist);

  return output;
}

@fragment
fn fs_sceneY(fsInput: VertexOutput) -> @location(0) vec4f {
  // DON'T REMOVE THESE (keeps uniform bindings active):
  var something = inputs.viz;
  something = inputs.twist;
  something = inputs.fov;

  var color = render(fsInput);

  // Apply magenta tint (1.0 = full magenta, 0.0 = original colors)
  let magenta = vec3f(1.0, 0.0, 1.0);
  let luminance = dot(color, vec3f(0.299, 0.587, 0.114));
  let tinted = magenta * luminance;
  color = mix(color, tinted, fsInput.tint);

  // Pink background fade from sceneT (1.0 = full pink, 0.0 = normal)
  let pink = vec3f(1.0, 0.0, 1.0);
  color = mix(color, pink, fsInput.bg_pink);

  return vec4f(color, 1.0);
}
