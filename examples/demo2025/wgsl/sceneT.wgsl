struct PngineInputs {
  time: f32,
  canvasW: f32,
  canvasH: f32,
  canvasRatio: f32,
};

struct SceneTInputs {
  recursion: f32,
  zoom: f32,
}

@group(0) @binding(0) var<uniform> pngine: PngineInputs;
@group(0) @binding(1) var<uniform> inputs: SceneTInputs;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
  @location(1) correctedUv: vec2f,

  @location(2) recursion: f32,
  @location(3) zoom: f32,
  @location(4) beat: f32,
}

@vertex
fn vs_sceneT(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
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
  output.beat = beat;

  // Recursion: 0 for first 3 beats, then increases to 16 during intro
  if (beat < ZOOM_START_DELAY) {
    output.recursion = intro_recursion(beat);
  } else {
    output.recursion = 16.0;
  }

  // Zoom steps on every beat using bar4
  output.zoom = zoom_bpm(beat);

  return output;
}

const ZOOM_START_DELAY: f32 = 16.0;  // delay in beats before zoom starts

// Pseudo-random hash for intro positions
fn hash11(p: f32) -> f32 {
  var p2 = fract(p * 0.1031);
  p2 *= p2 + 33.33;
  p2 *= p2 + p2;
  return fract(p2);
}

struct IntroTransform {
  pos: vec2f,
  scale: f32,
}

// Returns position/scale for intro beats - instant jumps, no easing
fn intro_transform(beat: f32) -> IntroTransform {
  let beat_idx = floor(beat);

  // Generate pseudo-random position and scale for each beat
  let rx = hash11(beat_idx * 1.0) * 2.0 - 1.0;       // -1 to 1
  let ry = hash11(beat_idx * 2.0 + 7.0) * 2.0 - 1.0; // -1 to 1
  let rs = hash11(beat_idx * 3.0 + 13.0);            // 0 to 1

  var result: IntroTransform;
  result.pos = vec2f(rx * 0.8, ry * 0.6);  // random position
  result.scale = 0.3 + rs * 0.5;           // scale between 0.3 and 0.8

  return result;
}

// Recursion during intro: 0 for first 3 beats, then increases smoothly to 16
fn intro_recursion(beat: f32) -> f32 {
  if (beat < 3.0) {
    return 0.0;
  }
  // After beat 3, increase smoothly (integer part + fractional blend)
  let beats_after_3 = beat - 3.0;
  return min(beats_after_3 + 1.0, 16.0);
}

const ZOOM_PULLBACK_START: f32 = 64.0;  // beat when pullback starts
const ZOOM_PULLBACK_DURATION: f32 = 8.0;  // beats of backward motion
const ZOOM_PULLBACK_AMOUNT: f32 = 2.0;    // how far back to pull

// Transition to black with cat face
const TRANSITION_START: f32 = 28.0;       // beat when cat face starts appearing
const TRANSITION_CAT_DURATION: f32 = 8.0; // beats for cat to fully appear
const TRANSITION_BLACK_START: f32 = 35.0; // beat when fade to black starts
const TRANSITION_BLACK_DURATION: f32 = 1.0; // fade to black in 1 beat

fn zoom_bpm(original_beat: f32) -> f32 {
  let delayed_beat = max(original_beat - ZOOM_START_DELAY, 0.0);

  // Smooth stepping: each beat adds 1.0 with smoothstep easing
  let beat_idx = floor(delayed_beat);
  let beat_frac = fract(delayed_beat);
  let eased_frac = smoothstep(0.0, 1.0, beat_frac);

  var zoom = (beat_idx + eased_frac) / 4.0;  // divide by 4 to slow down

  // Pullback effect: go backward for a couple beats, then forward again
  let pullback_beat = original_beat - ZOOM_START_DELAY - ZOOM_PULLBACK_START;
  if (pullback_beat > 0.0 && pullback_beat < ZOOM_PULLBACK_DURATION) {
    // Sine curve: goes down then back up
    let pullback_t = pullback_beat / ZOOM_PULLBACK_DURATION;
    let pullback = sin(pullback_t * PI) * ZOOM_PULLBACK_AMOUNT;
    zoom -= pullback;
  }

  return zoom / BEAT_SECS;
}

struct SDFResult {
  dist: f32,
  color: vec3f,
}

struct Domain2D {
    dist: f32,
    uv: vec2f,
};

const SQUARE_HALF: f32 = 0.35355339059;   // side/2 in the rotated frame
const CHILD_SCALE: f32 = 1.0 / SQUARE_HALF; // ~2.828427 (2*sqrt(2))

fn squareDomain(p_world: vec2f) -> Domain2D {
    // 1) Move to square center
    var p = p_world - vec2f(0.5, 0.0);

    // 2) Rotate so square becomes axis-aligned
    let c = cos(PI * 0.25);  // 45°
    let s = sin(PI * 0.25);
    let q = vec2f(
        c * p.x + s * p.y,
       -s * p.x + c * p.y
    );

    // 3) Distance to the axis-aligned square (same as tangramSquare internals)
    let dist = box(q, vec2f(SQUARE_HALF, SQUARE_HALF));

    // 4) Map q in square to uv in [-1,1]²
    let uv = q / SQUARE_HALF;

    return Domain2D(dist, uv);
}

fn evalTangramSDF(p: vec2f) -> SDFResult {
    var result = SDFResult(AWAY, vec3f(0.0));

    for (var i = 0u; i < 7u; i++) {
        let d = tangramPieceSDF(p, pieces[i], NO_TRANSFORM);
        if (d < result.dist) {
            result.dist = d;
            result.color = pieces[i].color;
        }
    }

    return result;
}

fn renderRecursiveTangram(fsInput: VertexOutput, p_screen: vec2f, transform: Transform2D) -> SDFResult {
    var p = transform_to_local(p_screen, transform);
    var scale_acc = 1.0;
    var depth = 0u;

    let max_depth = u32(fsInput.recursion);
    let blend_frac = fract(fsInput.recursion);  // fractional part for smooth blend

    // Limit recursion depth to avoid infinite loops
    for (var i = 0u; i < max_depth; i++) {
        let dom = squareDomain(p);

        // For the deepest level, use blend_frac to shrink threshold (smooth entry)
        var threshold = 0.05 / f32(i + 1);
        if (i == max_depth - 1u) {
            // Expand threshold as blend_frac goes 0->1, making level "grow in"
            threshold = threshold / max(blend_frac, 0.01);
        }

        // If we're NOT inside the square, stop recursing
        if (dom.dist >= threshold) {
            break;
        }

        // We ARE inside the square → go one level deeper
        p = dom.uv;              // new world space is the square's local uv
        scale_acc *= CHILD_SCALE; // distances grow by this factor at this level
        depth++;
    }

    // Now p is in the "deepest" tangram's coordinate system
    var res = evalTangramSDF(p);

    // Scale SDF distance back to the original screen scale
    res.dist *= scale_acc;
    res.dist = scale_sdf_distance(res.dist, transform);

    return res;
}


fn scene_sdf(fsInput: VertexOutput, p: vec2f, transform: Transform2D) -> SDFResult {
  let q = transform_to_local(p, transform);
  let beat = fsInput.beat;

  var scale: f32;
  var scaleTargetPt: vec2f;
  var scaleAnchor: vec2f;

  if (beat < ZOOM_START_DELAY) {
    // Intro: instant jumps to random positions each beat
    let intro = intro_transform(beat);
    scale = intro.scale;
    scaleTargetPt = intro.pos;
    scaleAnchor = vec2f(0.0, 0.0);
  } else {
    // After intro: normal zoom behavior
    scale = pow(CHILD_SCALE, (fsInput.zoom * 18.0) - 0.666);
    scaleTargetPt = vec2f(-0.6, -0.2) * vec2f(scale);
    scaleAnchor = vec2f(0.6, 0.2);
  }

  let angle = 0.0;
  let result = renderRecursiveTangram(fsInput, q, Transform2D(scaleTargetPt, angle, vec2f(scale, scale), scaleAnchor));


  // var result = SDFResult(1e10, vec3f(0.0));

  // result.dist = box(q, vec2f(0.25, 0.25));
  // result.color = vec3f(1.0, 0.7, 0.9);

  return result;
}

fn render(fsInput: VertexOutput, time: f32, transform: Transform2D) -> vec3f {
  let correctedUv = fsInput.correctedUv;  // Aspect-corrected UV for shapes
  let pix_uv = pixelate_uv(correctedUv, 400.0);

  let sdf = scene_sdf(fsInput, correctedUv, transform);
  let d = sdf.dist;

  if (d > 0.0) {
    // Blur/pixelate starts at 1.0 at beat start, clears to 0.0
    let beat_effect = 1.0 - fract(fsInput.beat);
    // Pixelation: low res at beat start (20), high res as beat progresses (200)
    let pixel_res = mix(200.0, 20.0, beat_effect);
    let bg_uv = pixelate_uv(correctedUv, pixel_res * (1.0 - fsInput.zoom + 0.1));
    return background(bg_uv, correctedUv, time, beat_effect);
  }

  // Shape fill with halftone dots pattern (same as sceneR)
  var col = sdf.color;
  let dots = sin(pix_uv.x * 120.0) * sin(pix_uv.y * 120.0);
  col += vec3f(0.05) * dots;

  return col;
}

fn background(pix_uv: vec2f, orig_uv: vec2f, t: f32, blur_amount: f32) -> vec3f {
    if (blur_amount < 0.01) {
        return spiralWithCats(pix_uv, orig_uv, t);
    }

    // Spiral blur - samples along a spiral path
    let blur_size = blur_amount * 0.2;
    var col = vec3f(0.0);
    let num_samples = 12u;

    for (var i = 0u; i < num_samples; i++) {
        let fi = f32(i) / f32(num_samples);
        // Spiral outward: angle increases, radius increases
        let angle = fi * 6.28318 * 2.0;  // 2 full rotations
        let radius = fi * blur_size;
        let offset = vec2f(cos(angle), sin(angle)) * radius;
        col += spiralWithCats(pix_uv + offset, orig_uv + offset, t);
    }

    return col / f32(num_samples);
}

// Soft cat silhouettes in background using catFaceLogo
const CAT_SILHOUETTES_FADEOUT_START: f32 = 24.0;  // beat when silhouettes start fading
const CAT_SILHOUETTES_FADEOUT_DURATION: f32 = 4.0; // beats to fully fade out

fn catSilhouettes(uv: vec2f, t: f32) -> f32 {
  var silhouette = 0.0;

  // Beat-synced bounce with easing
  let beat = t * BEAT_SECS;
  let beat_frac = fract(beat);
  let bounce = smoothstep(0.0, 1.0, beat_frac);  // eased 0->1 each beat
  let bounce_offset = (1.0 - bounce) * 0.08;     // starts high, settles down

  // Fade out before transition
  let fadeout = 1.0 - clamp((beat - CAT_SILHOUETTES_FADEOUT_START) / CAT_SILHOUETTES_FADEOUT_DURATION, 0.0, 1.0);
  if (fadeout <= 0.0) {
    return 0.0;
  }

  // Cat 1 - top left, drifting + beat bounce
  let pos1 = vec2f(-0.7, 0.5) + vec2f(sin(t * 0.3) * 0.15, cos(t * 0.2) * 0.1)
           + vec2f(-bounce_offset, bounce_offset);
  let cat1 = catFaceLogo(uv, 5.0, 0.0, Transform2D(pos1, 0.0, vec2f(1.0, -1.0), vec2f()));
  silhouette = max(silhouette, smoothstep(0.03, -0.02, cat1) * 0.7);

  // Cat 2 - top right + beat bounce (different direction)
  let pos2 = vec2f(0.7, 0.45) + vec2f(cos(t * 0.25) * 0.12, sin(t * 0.3) * 0.1)
           + vec2f(bounce_offset, bounce_offset);
  let cat2 = catFaceLogo(uv, 5.0, 0.0, Transform2D(pos2, 0.0, vec2f(0.9, -0.9), vec2f()));
  silhouette = max(silhouette, smoothstep(0.03, -0.02, cat2) * 0.65);

  // Cat 3 - bottom left + beat bounce
  let pos3 = vec2f(-0.65, -0.5) + vec2f(sin(t * 0.2) * 0.1, cos(t * 0.35) * 0.12)
           + vec2f(-bounce_offset, -bounce_offset);
  let cat3 = catFaceLogo(uv, 5.0, 0.0, Transform2D(pos3, 0.0, vec2f(0.85, -0.85), vec2f()));
  silhouette = max(silhouette, smoothstep(0.03, -0.02, cat3) * 0.6);

  // Cat 4 - bottom right + beat bounce
  let pos4 = vec2f(0.65, -0.45) + vec2f(cos(t * 0.28) * 0.1, sin(t * 0.22) * 0.1)
           + vec2f(bounce_offset, -bounce_offset);
  let cat4 = catFaceLogo(uv, 5.0, 0.0, Transform2D(pos4, 0.0, vec2f(0.8, -0.8), vec2f()));
  silhouette = max(silhouette, smoothstep(0.03, -0.02, cat4) * 0.55);

  return silhouette * fadeout;
}

fn spiral(uv: vec2f, t: f32) -> vec3f {
  let center = uv - vec2f(0.5);
  let angle = atan2(center.y, center.x);
  let radius = length(center);

  let spiral_val = sin(angle * 3.0 + radius * 10.0 - t * 2.5) * 0.5 + 0.5;

  let purple = vec3f(1.0, 0.0, 1.0);
  let darkPurple = vec3f(0.3, 0.0, 0.3);

  var color = mix(darkPurple, purple, spiral_val);

  return color;
}

// Spiral with cat silhouettes (using original non-pixelated UVs for cats)
fn spiralWithCats(pix_uv: vec2f, orig_uv: vec2f, t: f32) -> vec3f {
  var color = spiral(pix_uv, t);

  // Add soft cat silhouettes using original UVs (not pixelated)
  let cats = catSilhouettes(orig_uv, t);
  let catColor = vec3f(0.15, 0.0, 0.15);  // very dark purple for silhouettes
  color = mix(color, catColor, cats);

  return color;
}

fn water(uv: vec2f, t: f32) -> vec3f {
  // Horizontal bands
  let bands = sin(uv.y * 15.0 + t * 4.0) * 0.5 + 0.5;
  let flow = uv.x + sin(t * 2.0) * 0.1;

  let cyan = vec3f(0.0, 1.0, 1.0);
  let darkCyan = vec3f(0.0, 0.3, 0.3);

  let color = mix(darkCyan, cyan, bands * flow);

  return color;
}

// Cat face transition overlay
fn catFaceTransition(uv: vec2f, beat: f32) -> vec4f {
  // Calculate transition progress
  let cat_progress = clamp((beat - TRANSITION_START) / TRANSITION_CAT_DURATION, 0.0, 1.0);
  let black_progress = clamp((beat - TRANSITION_BLACK_START) / TRANSITION_BLACK_DURATION, 0.0, 1.0);

  if (cat_progress <= 0.0) {
    return vec4f(0.0, 0.0, 0.0, 0.0);  // no overlay yet
  }

  // Cat face SDF - grows in from center
  let cat_scale = mix(0.5, 5.0, cat_progress);  // cat grows as it appears
  let cat_transform = Transform2D(vec2f(0.0, 0.0), 0.0, vec2f(cat_scale, -cat_scale), vec2f());
  let cat_dist = catFaceLogo(uv, 5.0, 0.0, cat_transform);

  // Cat silhouette: magenta on black, fading in
  var cat_color = vec3f(0.0);  // black background
  if (cat_dist < 0.0) {
    // Inside cat face - magenta color
    cat_color = vec3f(1.0, 0.0, 1.0) * (1.0 - black_progress);
  }

  // Alpha: how much the cat overlay shows
  let overlay_alpha = cat_progress;

  // Fade everything to black at the end
  cat_color = cat_color * (1.0 - black_progress);

  return vec4f(cat_color, overlay_alpha);
}

@fragment
fn fs_sceneT(fsInput: VertexOutput) -> @location(0) vec4f {
  let t = pngine.time;
  let uv = fsInput.uv;
  let beat = fsInput.beat;

  var foo1 = inputs.recursion;
  var foo2 = inputs.zoom;

  var sceneTransform: Transform2D;
  sceneTransform.pos = vec2f(0.0, 0.0);
  sceneTransform.anchor = vec2f(0.0, 0.0);
  sceneTransform.angle = 0.0;

  let scale = 0.35;
  sceneTransform.scale = vec2f(scale);

  var color = render(fsInput, t, sceneTransform);

  // Apply cat face transition overlay
  let transition = catFaceTransition(fsInput.correctedUv, beat);
  color = mix(color, transition.rgb, transition.a);

  // Final fade to black
  let black_progress = clamp((beat - TRANSITION_BLACK_START) / TRANSITION_BLACK_DURATION, 0.0, 1.0);
  color = color * (1.0 - black_progress);

  return vec4f(color, 1.0);
}

