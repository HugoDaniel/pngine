struct Transform2D {
  pos: vec2f,      // World position
  angle: f32,      // Rotation in RADIANS
  scale: vec2f,    // 2D scale factors
  anchor: vec2f,   // Rotation anchor
};

const NO_TRANSFORM = Transform2D(vec2f(0.0), 0.0, vec2f(1.0), vec2f(0.0));

fn transform_to_local(uv: vec2f, xform: Transform2D) -> vec2f {
  var p = uv - xform.pos;
  let c = cos(xform.angle);
  let s = sin(xform.angle);
  p = vec2f(c * p.x + s * p.y, -s * p.x + c * p.y);
  p -= xform.anchor;
  p /= xform.scale;
  return p;
}

fn scale_sdf_distance(dist: f32, xform: Transform2D) -> f32 {
  if (abs(xform.scale.x - xform.scale.y) < 0.001) {
    return dist * xform.scale.x;
  }
  let ratio = max(xform.scale.x, xform.scale.y) / min(xform.scale.x, xform.scale.y);
  if (ratio < 2.0) {
    return dist * (2.0 / (1.0 / xform.scale.x + 1.0 / xform.scale.y));
  }
  return dist * min(xform.scale.x, xform.scale.y);
}

fn mixTransform(a: Transform2D, b: Transform2D, t: f32) -> Transform2D {
    var result: Transform2D;
    result.pos = mix(a.pos, b.pos, t);
    result.scale = mix(a.scale, b.scale, t);
    result.anchor = mix(a.anchor, b.anchor, t);
    result.angle = mix(a.angle, b.angle, t);
    return result;
}

fn pixelate_uv(uv: vec2f, grid_size: f32) -> vec2f {
    return (floor(uv * grid_size) + 0.5) / grid_size;
}

fn dots_uv(uv: vec2f, grid_size: f32, radius: f32) -> f32 {
    let local_uv = fract(uv * grid_size) - 0.5;
    
    return length(local_uv) - radius;
}
