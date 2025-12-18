struct PngineInputs {
  time: f32,
  canvasW: f32,
  canvasH: f32,
  canvasRatio: f32,
};

@group(0) @binding(0) var<uniform> pngine: PngineInputs;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
  @location(1) correctedUv: vec2f,

  @location(2) shape_t: f32,
  @location(3) beat_t: f32,
  @location(4) anim_t: f32,

  // Precomputed transforms (pos.xy, angle) - computed in vertex shader!
  @location(5) @interpolate(flat) t0: vec3f,
  @location(6) @interpolate(flat) t1: vec3f,
  @location(7) @interpolate(flat) t2: vec3f,
  @location(8) @interpolate(flat) t3: vec3f,
  @location(9) @interpolate(flat) t4: vec3f,
  @location(10) @interpolate(flat) t5: vec3f,
  @location(11) @interpolate(flat) t6: vec3f,
}

// Animation cycle duration in beats (one full closed->shape->closed cycle)
const CYCLE_BEATS: f32 = 8.0;

fn shape_bpm(original_beat: f32) -> f32 {
  // Shape changes at the start of each cycle (when pieces are closed)
  // 6 cat shapes total (indices 0-5)
  return floor(original_beat / CYCLE_BEATS) % 6.0;
}

fn anim_bpm(original_beat: f32) -> f32 {
  // Smooth 0.0 -> 1.0 over CYCLE_BEATS
  // 0.0 = closed, 0.5 = at shape, 1.0 = closed again
  return fract(original_beat / CYCLE_BEATS);
}

// Returns 1.0 at beat start, decays to 0.0
fn beat_pulse(beat: f32) -> f32 {
    let beat_frac = fract(beat);
    // Sharp attack, smooth decay
    return pow(1.0 - beat_frac, 3.0);
}

fn background(uv: vec2f, t: f32, beat: f32) -> vec3f {
    // Radial gradient from center
    let radius = length(uv);
    let radial = 1.0 - smoothstep(0.0, 2.5, radius);

    // Animated wave pattern - amplified
    let wave1 = sin(uv.x * 8.0 + t * 3.0) * sin(uv.y * 8.0 - t * 2.0);
    let wave2 = sin(uv.x * 12.0 - t * 1.5) * cos(uv.y * 6.0 + t * 2.5);
    let wave = (wave1 + wave2 * 0.5) * 0.5 + 0.5;

    // Color palette - more vibrant
    let color1 = vec3f(1.0, 0.85, 0.7);   // Warm cream
    let color2 = vec3f(0.5, 0.35, 0.5);   // Deep purple
    let color3 = vec3f(0.9, 0.5, 0.3);    // Orange accent

    // Mix based on radial and wave
    var bg_col = mix(color2, color1, radial * 0.8 + wave * 0.2);
    bg_col = mix(bg_col, color3, wave * radial * 0.3);

    // Beat pulse brightens background
    let pulse = beat_pulse(beat);
    bg_col += vec3f(0.15) * pulse;

    return bg_col;
}

struct SDFResult {
  dist: f32,
  color: vec3f,
}

// Get shape transform for a piece using switch (avoids nested array indexing)
fn get_shape_transform(shape_idx: u32, piece_index: u32) -> Transform2D {
    switch shape_idx {
        case 0u: { return state_cat1[piece_index]; }
        case 1u: { return state_cat2[piece_index]; }
        case 2u: { return state_cat3[piece_index]; }
        case 3u: { return state_cat4[piece_index]; }
        case 4u: { return state_cat5[piece_index]; }
        case 5u: { return state_cat6[piece_index]; }
        default: { return state_heart[piece_index]; }
    }
}

// Get opened transform for a piece using switch (avoids nested array indexing)
fn get_opened_transform(shape_idx: u32, piece_index: u32) -> Transform2D {
    switch shape_idx {
        case 0u: { return state_opened1[piece_index]; }
        case 1u: { return state_opened2[piece_index]; }
        case 2u: { return state_opened3[piece_index]; }
        case 3u: { return state_opened4[piece_index]; }
        case 4u: { return state_opened5[piece_index]; }
        case 5u: { return state_opened6[piece_index]; }
        default: { return state_opened7[piece_index]; }
    }
}

// Lerp between two Transform2D
fn lerp_transform(a: Transform2D, b: Transform2D, t: f32) -> Transform2D {
    return Transform2D(
        mix(a.pos, b.pos, t),
        mix(a.angle, b.angle, t),
        mix(a.scale, b.scale, t),
        mix(a.anchor, b.anchor, t)
    );
}

fn get_animated_transform(piece_index: u32, shape_idx: u32, anim_t: f32) -> Transform2D {
    // anim_t goes 0.0 -> 1.0 over CYCLE_BEATS (8 beats)
    // 5 phases: closed -> opened -> cat -> HOLD -> opened -> closed
    // Shape only changes when anim_t wraps around to 0.0

    let closed = state_closed[piece_index];
    // Use single opened state (no switch) for performance
    let opened = state_opened1[piece_index];
    let cat = get_shape_transform(shape_idx, piece_index);

    if (anim_t < 0.25) {
        // Phase 1: Closed -> Opened (0.0 to 0.25) - 2 beats
        let t = smoothstep(0.0, 0.25, anim_t);
        return lerp_transform(closed, opened, t);
    } else if (anim_t < 0.5) {
        // Phase 2: Opened -> Cat (0.25 to 0.5) - 2 beats
        let t = smoothstep(0.25, 0.5, anim_t);
        return lerp_transform(opened, cat, t);
    } else if (anim_t < 0.75) {
        // Phase 3: Cat HOLD (0.5 to 0.75) - 2 beats
        return cat;
    } else if (anim_t < 0.875) {
        // Phase 4: Cat -> Opened (0.75 to 0.875) - 1 beat
        let t = smoothstep(0.75, 0.875, anim_t);
        return lerp_transform(cat, opened, t);
    } else {
        // Phase 5: Opened -> Closed (0.875 to 1.0) - 1 beat
        let t = smoothstep(0.875, 1.0, anim_t);
        return lerp_transform(opened, closed, t);
    }
}

// Helper to pack Transform2D into vec3f (pos.xy, angle) - scale/anchor assumed (1,1)/(0,0)
fn pack_transform(t: Transform2D) -> vec3f {
  return vec3f(t.pos, t.angle);
}

@vertex
fn vs_sceneR(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
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
  output.shape_t = shape_bpm(beat);
  output.beat_t = beat_pulse(beat);
  output.anim_t = anim_bpm(beat);

  // PRECOMPUTE all 7 transforms in vertex shader (runs 3x total, not per-pixel!)
  let shape_idx = u32(output.shape_t);
  let anim_t = output.anim_t;
  output.t0 = pack_transform(get_animated_transform(0u, shape_idx, anim_t));
  output.t1 = pack_transform(get_animated_transform(1u, shape_idx, anim_t));
  output.t2 = pack_transform(get_animated_transform(2u, shape_idx, anim_t));
  output.t3 = pack_transform(get_animated_transform(3u, shape_idx, anim_t));
  output.t4 = pack_transform(get_animated_transform(4u, shape_idx, anim_t));
  output.t5 = pack_transform(get_animated_transform(5u, shape_idx, anim_t));
  output.t6 = pack_transform(get_animated_transform(6u, shape_idx, anim_t));

  return output;
}

fn get_glow_intensity(dist: f32, radius: f32, intensity: f32) -> f32 {
    return smoothstep(radius, 0.0, max(dist, 0.0)) * intensity;
}

fn get_bayer_threshold(pos: vec2u) -> f32 {
    let x = pos.x % 4u;
    let y = pos.y % 4u;
    let index = x + y * 4u;
    var matrix = array<f32, 16>(
        0.0,  8.0,  2.0,  10.0,
        12.0, 4.0,  14.0, 6.0,
        3.0,  11.0, 1.0,  9.0,
        15.0, 7.0,  13.0, 5.0
    );
    return matrix[index] / 16.0;
}

// Outline-only glow - applies only outside shapes
fn applyRetroDitherGlow(bg_color: vec3f, dist: f32, glow_color: vec3f, pixel_coords: vec2u) -> vec3f {
    // Only apply glow outside shapes (dist > 0)
    if (dist <= 0.0) {
        return bg_color;
    }
    // Tight radius for sticker-like outline
    let smooth_glow = get_glow_intensity(dist, 0.15, 0.6);
    let threshold = get_bayer_threshold(pixel_coords);
    let dither_bit = step(threshold, smooth_glow);
    return bg_color + (glow_color * dither_bit);
}

// Dithered expanding ring that triggers every beat
fn beat_ring(uv: vec2f, beat: f32, pixel_coords: vec2u) -> vec3f {
    let beat_frac = fract(beat);

    // Ring expands from center
    let ring_radius = beat_frac * 3.0;  // Expands outward
    let ring_width = 0.15;

    let dist_from_center = length(uv);
    let ring_dist = abs(dist_from_center - ring_radius);

    // Ring intensity fades as it expands
    let fade = 1.0 - beat_frac;
    let ring_intensity = smoothstep(ring_width, 0.0, ring_dist) * fade;

    // Dither the ring
    let threshold = get_bayer_threshold(pixel_coords);
    let dither_bit = step(threshold, ring_intensity);

    // Cyan/teal color for contrast with hot pink
    let ring_color = vec3f(0.2, 0.9, 0.8);

    return ring_color * dither_bit;
}

fn get_drop_shadow(fsInput: VertexOutput, uv: vec2f, transform: Transform2D, offset: vec2f, blur: f32) -> f32 {
    let res = scene_sdf_from_vertex(uv - offset, transform, fsInput);
    return smoothstep(-blur, blur, res.dist);
}

fn renderTangram(fsInput: VertexOutput, uv: vec2f, transform: Transform2D) -> vec3f {
    let pixel_resolution = 400.0;
    let shadow_col = vec3f(0.0, 0.0, 0.15);
    let neon_stroke_col = vec3f(1.0, 0.2, 0.6); // Hot Pink
    let pixel_coords = vec2u(fsInput.position.xy);
    let beat = pngine.time * BEAT_SECS;

    // 1. Pixelate UV
    let pix_uv = pixelate_uv(uv, pixel_resolution);

    // 2. Geometry Pass - transforms precomputed in VERTEX SHADER!
    let shape = scene_sdf_from_vertex(pix_uv, transform, fsInput);

    // 3. Background
    var col = background(pix_uv, pngine.time, beat);

    // 4. Beat Ring
    col += beat_ring(fsInput.correctedUv, beat, pixel_coords);

    // 5. Dark Shadow Pass (now fast with vertex-precomputed transforms!)
    let shadow_mask = get_drop_shadow(fsInput, pix_uv, transform, vec2f(0.04, -0.04), 0.05);
    col = mix(mix(col, shadow_col, 0.5), col, shadow_mask);

    // 6. Pink Glow - bounces with beat!
    let beat_bounce = fsInput.beat_t;
    let pink_offset = vec2f(-0.06, 0.06) * (0.5 + beat_bounce * 1.5);
    let pink_blur = 0.04 + beat_bounce * 0.04;
    let pink_shadow_mask = get_drop_shadow(fsInput, pix_uv, transform, pink_offset, pink_blur);
    let pink_glow_intensity = (1.0 - pink_shadow_mask) * 0.8;
    let threshold = get_bayer_threshold(pixel_coords);
    let dither_bit = step(threshold, pink_glow_intensity);
    col += neon_stroke_col * dither_bit;

    // 7. Retro Dither Outline
    col = applyRetroDitherGlow(col, shape.dist, neon_stroke_col, pixel_coords);

    // 8. Object Fill
    if (shape.dist < 0.0) {
        col = shape.color;
        // Halftone dots
        let dots = sin(pix_uv.x * 120.0) * sin(pix_uv.y * 120.0);
        col += vec3f(0.05) * dots;
    }

    return col;
}

// Unpack vec3f (pos.xy, angle) back to Transform2D
fn unpack_transform(packed: vec3f) -> Transform2D {
    return Transform2D(packed.xy, packed.z, vec2f(1.0), vec2f(0.0));
}

// Fast SDF using precomputed transforms from vertex shader
fn scene_sdf_from_vertex(uv: vec2f, transform: Transform2D, fsInput: VertexOutput) -> SDFResult {
    let q = transform_to_local(uv, transform);
    var result = SDFResult(1e10, vec3f(0.0));

    // Unpack transforms from vertex output (precomputed, no switch!)
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
        let piece_dist = tangramPieceSDF(q, pieces[i], transforms[i]);
        let d = scale_sdf_distance(piece_dist, transform);

        if (d < result.dist) {
            result.dist = d;
            result.color = pieces[i].color;
        }
    }

    return result;
}

fn render_mode0(fsInput: VertexOutput, time: f32, pix_uv: vec2f, shape: SDFResult, transform: Transform2D) -> vec3f {
    let shadow_col = vec3f(0.0, 0.0, 0.15);
    let neon_stroke_col = vec3f(1.0, 0.2, 0.6);
    let beat = time * BEAT_SECS;
    let pixel_coords = vec2u(fsInput.position.xy);

    var col = background(pix_uv, time, beat);

    // Beat Ring
    col += beat_ring(fsInput.correctedUv, beat, pixel_coords);

    // Shadow Pass - now fast with vertex-precomputed transforms!
    let shadow_mask = get_drop_shadow(fsInput, pix_uv, transform, vec2f(0.04, -0.04), 0.05);
    col = mix(mix(col, shadow_col, 0.5), col, shadow_mask);

    // Outline-only dither glow (uses shape.dist directly)
    col = applyRetroDitherGlow(col, shape.dist, neon_stroke_col, pixel_coords);

    // Object Fill
    if (shape.dist < 0.0) {
        col = shape.color;
        let dots = sin(pix_uv.x * 120.0) * sin(pix_uv.y * 120.0);
        col += vec3f(0.05) * dots;
    }

    return col;
}

fn render_mode1(fsInput: VertexOutput, time: f32, pix_uv: vec2f, shape: SDFResult, transform: Transform2D) -> vec3f {
    let shadow_col = vec3f(0.0, 0.0, 0.15);
    let pink_shadow_col = vec3f(1.0, 0.2, 0.6); // Hot pink
    let dark_bg = vec3f(0.1, 0.1, 0.12);
    let pixel_coords = vec2u(fsInput.position.xy);

    var col = dark_bg;

    // Dark shadow (static) - now fast with vertex-precomputed transforms!
    let shadow_mask = get_drop_shadow(fsInput, pix_uv, transform, vec2f(0.04, -0.04), 0.05);
    col = mix(mix(col, shadow_col, 0.5), col, shadow_mask);

    // Pink shadow - bounces with beat!
    let beat_bounce = fsInput.beat_t;
    let pink_offset = vec2f(-0.06, 0.06) * (0.5 + beat_bounce * 1.5);
    let pink_blur = 0.04 + beat_bounce * 0.04;
    let pink_shadow_mask = get_drop_shadow(fsInput, pix_uv, transform, pink_offset, pink_blur);

    // Dithered pink glow on the shadow edge
    let pink_glow_intensity = (1.0 - pink_shadow_mask) * 0.8;
    let threshold = get_bayer_threshold(pixel_coords);
    let dither_bit = step(threshold, pink_glow_intensity);
    col += pink_shadow_col * dither_bit;

    // Object Fill with halftone
    if (shape.dist < 0.0) {
        col = shape.color;
        let dots = sin(pix_uv.x * 120.0) * sin(pix_uv.y * 120.0);
        col += vec3f(0.05) * dots;
    }

    return col;
}

fn render(fsInput: VertexOutput, time: f32, transform: Transform2D, neon_mode: f32) -> vec3f {
    let pixel_resolution = 400.0;

    // --- Single SDF evaluation for the whole render ---
    let pix_uv = pixelate_uv(fsInput.correctedUv, pixel_resolution);
    let shape = scene_sdf_from_vertex(pix_uv, transform, fsInput);

    // Early-out: only compute the active mode (avoid computing both)
    if (neon_mode < 0.01) {
        return render_mode0(fsInput, time, pix_uv, shape, transform);
    } else if (neon_mode > 0.99) {
        return render_mode1(fsInput, time, pix_uv, shape, transform);
    } else {
        // Only blend during transitions (rare)
        let col0 = render_mode0(fsInput, time, pix_uv, shape, transform);
        let col1 = render_mode1(fsInput, time, pix_uv, shape, transform);
        return mix(col0, col1, neon_mode);
    }
}

// Control variable: 0.0 = current vibrant look, 1.0 = original pink neon dither
fn neon_mode_bpm(original_beat: f32) -> f32 {
    // Example: can be driven by beat, or set to constant
    // For now, return 0.0 (current look) - change to 1.0 for neon mode
    // Or animate it based on phase/beat
    let phase = floor(original_beat / 8.0) % 4.0;

    // Example: alternate between modes every 16 beats
    return step(2.0, phase); // 0.0 for phase 0-1, 1.0 for phase 2-3

    // return smoothstep(0.0, 1.0, phase);
    // return 0.0; // Default: current look. Set to 1.0 for neon mode
}

@fragment
fn fs_sceneR(fsInput: VertexOutput) -> @location(0) vec4f {
  let t = pngine.time;
  let beat = t * BEAT_SECS;

  // Scene transform
  var sceneTransform: Transform2D;
  sceneTransform.pos = vec2f(0.0, 0.0);
  sceneTransform.anchor = vec2f(0.0, 0.0);
  sceneTransform.angle = PI;
  let scale = 0.35;
  sceneTransform.scale = vec2f(-scale, scale);

  // Switch between modes based on beat (mode0 = vibrant, mode1 = dark neon pink)
  let neon_mode = neon_mode_bpm(beat);
  let color = render(fsInput, t, sceneTransform, neon_mode);

  return vec4f(color, 1.0);
}
