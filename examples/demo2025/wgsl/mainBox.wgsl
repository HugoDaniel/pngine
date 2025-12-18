
struct BoxLayer {
    type_id: u32, // 0 box body; 1; eye
    color: vec3f,
    transform: Transform2D,
}


const BoxLayersLength: u32 = 3;
const BoxLayers = array<BoxLayer, BoxLayersLength>(
  // 2 eyes:
  BoxLayer(1, vec3f(1.0), Transform2D(vec2f(0.07, -0.035), 0.0, vec2f(1.0), vec2f(0.0))),
  BoxLayer(1, vec3f(1.0), Transform2D(vec2f(-0.07, -0.035), 0.0, vec2f(1.0), vec2f(0.0))),
  // body:
  BoxLayer(0, vec3f(0.0), NO_TRANSFORM)
);

fn box_eye(p: vec2f, eye: BoxLayer, eyelid_t: f32) -> f32 {
  let eyeRatio = 2.87;
  let eyeW = 0.03;
  let eyeRadius = eyeW * 0.6;
  let eyeH = eyeW * eyeRatio;

  // Local space
  let eyeQ = transform_to_local(p, eye.transform);

  // Rounded box eye SDF
  let eyeSdf = box(eyeQ, vec2f(eyeW - eyeRadius, eyeH - eyeRadius)) - eyeRadius;

  // ----- Eyelid clipping from TOP -----
  let t = clamp(eyelid_t, 0.0, 1.0);

  // In Y-down coords:
  //   top ≈ -eyeH, bottom ≈ +eyeH
  // Lid moves from top (-eyeH) to bottom (+eyeH)
  let lidY = mix(-eyeH, eyeH + 0.01, t);

  // Half-space: keep region *below* the lid (y > lidY)
  // For y > lidY: lidSdf < 0 (inside allowed), y < lidY: lidSdf > 0 (clipped)
  let lidSdf = lidY - eyeQ.y;

  // Intersection: eye ∩ half-space
  let clippedEye = max(eyeSdf, lidSdf);

  return scale_sdf_distance(clippedEye, eye.transform);
}


fn box_full(p: vec2f, transform: Transform2D) -> f32 {
  return transformedBox(p, BOX_SIZE, transform);
}

fn box_without_eyes(p: vec2f, transform: Transform2D, eyelid_t: f32) -> f32 {
  let q = transform_to_local(p, transform);

  let eye1 = box_eye(q, BoxLayers[0], eyelid_t);
  let eye2 = box_eye(q, BoxLayers[1], eyelid_t);

  
  let bodyPiece = BoxLayers[BoxLayersLength - 1];
  let t = bodyPiece.transform;
  let raw = max(-eye2, max(-eye1, box(transform_to_local(q, t), BOX_SIZE)));
  let box = scale_sdf_distance(raw, t); 
  return box;
}

fn box_layer_sdf(p: vec2f, piece: BoxLayer, transform: Transform2D, eyelid_t: f32) -> f32 {
  let q = transform_to_local(p, transform);
  let t = piece.transform;

  switch piece.type_id {
    case 0u: {  return box_without_eyes(q, t, eyelid_t); }
    case 1u: { // Eye
      let eyeRatio = 2.87;
      let eyeW = 0.03;
      let eyeRadius = eyeW *  0.6;
      let eyeH = eyeW * eyeRatio;
      let eyeQ = transform_to_local(q, t);
      let eye = box(eyeQ, vec2f(eyeW - eyeRadius, eyeH - eyeRadius)) - eyeRadius;
      return scale_sdf_distance(eye, t); 
    }
    default: { return AWAY; }
  }
}

