// Smooth minimum for SDF blending
fn smin(a: f32, b: f32, k: f32) -> f32 {
  if (k <= 0.0) {
    return min(a, b);
  }
  let h = max(k - abs(a - b), 0.0) / k;
  return min(a, b) - h * h * k * 0.25;
}

fn circle(p: vec2f, c: vec2f, r: f32) -> f32 {
    return distance(p, c) - r;
}

fn transformedCircle(p: vec2f, r: f32, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = circle(q, vec2f(0.0), r);

    return scale_sdf_distance(raw_dist, transform);
}


fn box(p: vec2f, b: vec2f) -> f32 {
  let d = abs(p) - b;
  return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0);
}

fn tri(p: vec2<f32>, p0: vec2<f32>, p1: vec2<f32>, p2: vec2<f32>) -> f32 {
    let e0 = p1 - p0; let e1 = p2 - p1; let e2 = p0 - p2;
    let v0 = p - p0; let v1 = p - p1; let v2 = p - p2;
    let pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0f, 1.0f);
    let pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0f, 1.0f);
    let pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0f, 1.0f);
    let s = sign(e0.x * e2.y - e0.y * e2.x);
    let d0 = vec2<f32>(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x));
    let d1 = vec2<f32>(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x));
    let d2 = vec2<f32>(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x));
    let d = min(min(d0, d1), d2);
    return -sqrt(d.x) * sign(d.y);
}

fn transformedTri(p: vec2f, p0: vec2<f32>, p1: vec2<f32>, p2: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = tri(q, p0, p1, p2);

    return scale_sdf_distance(raw_dist, transform);
}

fn parallelogram(p_in: vec2<f32>, wi: f32, he: f32, sk: f32) -> f32 {
    let e = vec2<f32>(sk, he);
    var p = p_in;
    if (p.y < 0.0f) { p = -p; }
    var w = p - e; w.x = w.x - clamp(w.x, -wi, wi);
    var d = vec2<f32>(dot(w, w), -w.y);
    let s = p.x * e.y - p.y * e.x;
    if (s < 0.0f) { p = -p; }
    var v = p - vec2<f32>(wi, 0.0f);
    v = v - e * clamp(dot(v, e) / dot(e, e), -1.0f, 1.0f);
    d = min(d, vec2<f32>(dot(v, v), wi * he - abs(s)));
    return sqrt(d.x) * sign(-d.y);
}

fn segment(p: vec2f, a: vec2f, b: vec2f, r: f32) -> f32 {
    let ba = b - a;
    let pa = p - a;
    let h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

fn transformedBox(p: vec2f, b: vec2f, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = box(q, b);
    return scale_sdf_distance(raw_dist, transform);
}

fn transformedParallelogram(p: vec2f, wi: f32, he: f32, sk: f32, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = parallelogram(q, wi, he, sk);
    return scale_sdf_distance(raw_dist, transform);
}


// 1. Define the constant for array size (must match the input array size)
const NUM: u32 = 6u;

fn sixPolygon(p: vec2f, v: array<vec2f, NUM>) -> f32 {
    // 2. Variable declarations
    // 'var' is mutable, 'let' is immutable.
    // We use explicit 'u' suffixes for unsigned integers used in indexing.
    
    // Initial distance to the first vertex
    var d = dot(p - v[0], p - v[0]);
    var s = 1.0;
    
    // Initialize j to the last element (N-1)
    var j = NUM - 1u;

    // 3. Loop Structure
    // Note: The "j=i, i++" GLSL logic is split. 
    // j is updated at the very bottom of the loop.
    for (var i = 0u; i < NUM; i++) {
        
        let e = v[j] - v[i];
        let w = p - v[i];

        // 4. Distance to segment calculation
        // clamp, dot, and min are standard built-ins in WGSL
        let b = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
        d = min(d, dot(b, b));

        // 5. Winding number logic
        // We construct a vec3<bool> explicitly.
        let cond = vec3<bool>(
            p.y >= v[i].y,
            (p.y < v[j].y),
            (e.x * w.y > e.y * w.x)
        );

        // 6. Boolean Logic
        // all() works on vec3<bool>. 
        // !cond negates the vector component-wise (equivalent to not(cond)).
        if (all(cond) || all(!cond)) {
            s = -s;
        }

        // 7. Update j for the next iteration (replacing the comma operator)
        j = i;
    }

    return s * sqrt(d);
}

