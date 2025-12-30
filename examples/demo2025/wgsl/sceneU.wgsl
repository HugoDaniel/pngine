struct PngineInputs {
  time: f32,
  canvasW: f32,
  canvasH: f32,
  canvasRatio: f32,
};

struct SceneUInputs {
  something_t: f32,
}

@group(0) @binding(0) var<uniform> pngine: PngineInputs;
@group(0) @binding(1) var<uniform> inputs: SceneUInputs;


struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
  @location(1) correctedUv: vec2f,
}

fn hash(p: vec2f) -> f32 {
    var p3 = fract(vec3f(p.xyx) * .1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

@vertex
fn vs_sceneU(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
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

  let beat = pngine.time * BEAT_SECS;
  output.correctedUv = corrected;
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

fn renderMT(uv: vec2f, transform: Transform2D) -> vec3f {
    let q = transform_to_local(uv, transform);

    // Start with bright magenta background (gamma correction will darken it)
    var result = SDFResult(1e10, vec3f(1.0, 0.0, 1.0));

    let boxColors = array<vec3f, 8>(
        vec3f(1.0),
        vec3<f32>(0.855, 0.827, 0.271),
        vec3<f32>(0.349, 0.780, 0.839),
        vec3<f32>(0.341, 0.741, 0.220),
        vec3<f32>(0.859, 0.251, 0.886),
        vec3<f32>(0.898, 0.212, 0.137),
        vec3<f32>(0.000, 0.122, 0.894),
        vec3f(0.0),
    );

    // Orange: vec3<f32>(1.000, 0.341, 0.200)
    // Use actual canvas aspect ratio instead of hardcoded 16:9
    let ratio = max(pngine.canvasRatio, 1.0);
    let boxSize = vec2f(ratio / 8.0, 1.0);
    for (var i = 0u; i < 8u; i++) {
        let boxD = transformedBox(q, boxSize, Transform2D(vec2f(-ratio + boxSize.x + 2.0 * ratio * f32(i)/ 8.0, 1.0 - boxSize.y), 0.0, vec2f(1.0), vec2f())) - 0.001;
        if (boxD < 0.0) {
            result.color = boxColors[i];
        }
    }

    // Grayscale boxes
    let grayscaleBoxesY = 0.2;
    let gbW = 2.0 * ratio / 5.0;
    let grayscaleBoxesSize = vec2f(ratio/5.0, 0.2);
    for (var i = 0u; i < 5u; i++) {
        // let grayscaleTransf = Transform2D(vec2f(f32(i) * grayscaleBoxesSize.x, grayscaleBoxesY), 0.0, vec2f(1.0), vec2f());
        let grayscaleTransf = Transform2D(vec2f(-ratio + f32(i) * gbW + gbW*0.5, grayscaleBoxesY), 0.0, vec2f(1.0), vec2f());
        let boxD = transformedBox(q, grayscaleBoxesSize, grayscaleTransf) - 0.001;
        if (boxD < 0.0) {
            result.color = vec3f(f32(i + 2) / 6.0); 
        }
    }

    // Gradients
    let gradientH = 0.15;
    let gradientW = ratio * 0.8;
    let gradient1Transf = Transform2D(vec2f(-gradientW * 0.5, -1.0 + gradientH * 3.0), 0.0, vec2f(1.0), vec2f());
    let gradient1D = transformedBox(q, vec2f(gradientW, gradientH), gradient1Transf) - 0.001;
    if (gradient1D < 0.0) {
        result.color = mix(vec3f(),vec3<f32>(1.000, 0.341, 0.200), (q.x / (2.0 * gradientW)) + gradientW * 0.600 ); 
    }

    let gradient2Transf = Transform2D(vec2f(-gradientW * 0.5, -1.0 + gradientH), 0.0, vec2f(1.0), vec2f());
    let gradient2D = transformedBox(q, vec2f(gradientW, gradientH), gradient2Transf) - 0.001;
    if (gradient2D < 0.0) {
        result.color = mix(vec3f(), vec3<f32>(0.404, 0.369, 0.965), (q.x / (2.0 * gradientW)) + gradientW * 0.600 ); 
    }

    // Noise boxes
    let noiseBoxH = gradientH * 2.0;
    let noiseBoxW = ratio * 0.2;
    
    let noiseBox1Transf = Transform2D(vec2f(ratio - noiseBoxW, -1.0 + noiseBoxH), 0.0, vec2f(1.0), vec2f());
    let noiseBox1D = transformedBox(q, vec2f(noiseBoxW, noiseBoxH), noiseBox1Transf) - 0.001;
    if (noiseBox1D < 0.0) {
        let noiseScale = 300.0;
        let seed = floor(q * noiseScale) + vec2f(pngine.time * 60.0);
        
        let n = hash(seed);
        result.color = vec3f(n); 
    }

    let noiseBox2Transf = Transform2D(vec2f(ratio - noiseBoxW * 3.0, -1.0 + noiseBoxH), 0.0, vec2f(1.0), vec2f());
    let noiseBox2D = transformedBox(q, vec2f(noiseBoxW, noiseBoxH), noiseBox2Transf) - 0.001;
    if (noiseBox2D < 0.0) {
        let blockScale = 30.0; 
        let timeStep = floor(pngine.time * 10.0); // 10 FPS look
        
        let seed = floor(q * blockScale);
        
        // Generate separate noise for R, G, and B for color noise
        let r = hash(seed + vec2f(timeStep, 0.0));
        let g = hash(seed + vec2f(timeStep, 10.0)); // Offset seed
        let b = hash(seed + vec2f(timeStep, 20.0)); // Offset seed
        
        result.color = vec3f(r, g, b); 
    }

    let catScale = 1.2;
    let catD = catFaceLogo(uv, 5.0, 0.0, Transform2D(vec2f(0.0, -0.2), 0.0, vec2f(catScale, -catScale), vec2f()));
    if (catD < 0.0) {
      result.color = vec3f(1.0);  // White cat logo (was black, invisible on black background)
    }
    
    return result.color;
}

fn render(fsInput: VertexOutput, time: f32, transform: Transform2D) -> vec3f {
  let correctedUv = fsInput.correctedUv;  // Aspect-corrected UV for shapes

  let miraTecnicaColor = renderMT(correctedUv, transform);

  return miraTecnicaColor;
}

fn background(uv: vec2f, t: f32) -> vec3f {
  // Spiral pattern
  let center = uv - vec2f(0.5);
  let angle = atan2(center.y, center.x);
  let radius = length(center);

  let spiral = sin(angle * 3.0 + radius * 10.0 - t * 2.5) * 0.5 + 0.5;

  let purple = vec3f(1.0, 0.0, 1.0);
  let darkPurple = vec3f(0.3, 0.0, 0.3);

  let color = mix(darkPurple, purple, spiral);

  return color;
}

@fragment
fn fs_sceneU(fsInput: VertexOutput) -> @location(0) vec4f {
  let t = pngine.time;
  let uv = fsInput.uv;

  let something = inputs.something_t;


  var sceneTransform: Transform2D;
  sceneTransform.pos = vec2f(0.0, 0.0);
  sceneTransform.anchor = vec2f(0.0, 0.0);
  sceneTransform.angle = 0.0;
  sceneTransform.scale = vec2f(1.0, -1.0);
  var color = render(fsInput, t, sceneTransform);

  color = pow(color, vec3f(2.2));

  return vec4f(color, 1.0);
}
