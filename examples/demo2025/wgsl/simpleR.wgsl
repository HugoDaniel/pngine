// simpleR — optimized tangram scene
// Compared to sceneR: inlined imports, no dead code, vec3f transforms,
// no opened scatter state, direct canvas render (no post-process pass-through),
// merged render modes, parametric piece SDF.

struct In { t: f32, w: f32, h: f32, a: f32 }
@group(0) @binding(0) var<uniform> u: In;

const pi = 3.14159265;
const BS = 170.0 / 60.0; // BPM as beats/sec
const CYC = 8.0;          // beats per shape cycle

// Rotate point by angle
fn R(p: vec2f, a: f32) -> vec2f {
  let c = cos(a); let s = sin(a);
  return vec2f(c*p.x + s*p.y, -s*p.x + c*p.y);
}

// --- Piece colors (7 tangram pieces) ---
const COL = array<vec3f, 7>(
  vec3f(.773,.561,.702), vec3f(.502,.749,.239), vec3f(.494,.325,.545),
  vec3f(.439,.573,.235), vec3f(.604,.137,.443), vec3f(.012,.522,.298),
  vec3f(.133,.655,.42)
);

// --- Triangle vertices for piece types 1-5 ---
const TV = array<vec2f, 15>(
  vec2f(-1,1), vec2f(0,0), vec2f(1,1),       // big tri 1
  vec2f(-1,1), vec2f(0,0), vec2f(-1,-1),     // big tri 2
  vec2f(1,-1), vec2f(1,0), vec2f(0,-1),      // mid tri
  vec2f(1,1),  vec2f(1,0), vec2f(.5,.5),     // small tri 1
  vec2f(0,0),  vec2f(.5,-.5), vec2f(-.5,-.5) // small tri 2
);

// --- Cat shapes: 6 cats x 7 pieces = 42 vec3f(x, y, angle) ---
// Closed state is vec3f(0) — pieces at origin. No storage needed.
const CATS = array<vec3f, 42>(
  // cat1
  vec3f(.7,.79,0), vec3f(-.5,0,-pi*.5), vec3f(-.5,-1.41,pi*1.25),
  vec3f(-.21,.29,pi*.25), vec3f(1.7,1.79,pi), vec3f(1.2,1.29,pi*.5),
  vec3f(-1,-.91,0),
  // cat2
  vec3f(.9,-.21,0), vec3f(-.8,-.5,pi), vec3f(.9,-.21,pi*.5),
  vec3f(-.095,.205,pi*1.75), vec3f(.9,-.21,0), vec3f(1.4,.29,pi*1.5),
  vec3f(-1.8,-.5,0),
  // cat3
  vec3f(-.1,.91,0), vec3f(-.51,-.5,-pi*.75), vec3f(.9,-.5,pi*1.75),
  vec3f(.9,-1.9,pi*1.25), vec3f(.9,1.91,pi), vec3f(.4,1.41,pi*.5),
  vec3f(.19,-.5,pi*.25),
  // cat4
  vec3f(-1.02,.5,0), vec3f(-.515,0,pi), vec3f(.9,0,pi*.25),
  vec3f(.19,-.71,pi*.25), vec3f(-1.02,.5,0), vec3f(-.52,1,pi*1.5),
  vec3f(1.61,-1.42,pi*.75),
  // cat5
  vec3f(-1,-.25,0), vec3f(.91,-.75,pi*.25), vec3f(1.61,-1.458,-pi*.25),
  vec3f(.2,-.04,pi*.25), vec3f(-1,-.25,0), vec3f(-.5,.25,pi*1.5),
  vec3f(.2,-.46,0),
  // cat6
  vec3f(1.3,-.86,pi*.666), vec3f(.91,-.75,pi*.666), vec3f(-1.675,-1.085,-pi*1.085),
  vec3f(.515,-.65,pi*1.416), vec3f(.61,-.67,pi*.16), vec3f(.8,.005,pi*1.666),
  vec3f(-2.49,.05,pi*.45)
);

// --- SDF primitives ---

fn sdf_box(p: vec2f, b: vec2f) -> f32 {
  let d = abs(p) - b;
  return length(max(d, vec2f(0))) + min(max(d.x, d.y), 0.0);
}

fn sdf_tri(p: vec2f, a: vec2f, b: vec2f, c: vec2f) -> f32 {
  let e0=b-a; let e1=c-b; let e2=a-c;
  let v0=p-a; let v1=p-b; let v2=p-c;
  let q0=v0-e0*clamp(dot(v0,e0)/dot(e0,e0),0.0,1.0);
  let q1=v1-e1*clamp(dot(v1,e1)/dot(e1,e1),0.0,1.0);
  let q2=v2-e2*clamp(dot(v2,e2)/dot(e2,e2),0.0,1.0);
  let s=sign(e0.x*e2.y-e0.y*e2.x);
  let d=min(min(
    vec2f(dot(q0,q0), s*(v0.x*e0.y-v0.y*e0.x)),
    vec2f(dot(q1,q1), s*(v1.x*e1.y-v1.y*e1.x))),
    vec2f(dot(q2,q2), s*(v2.x*e2.y-v2.y*e2.x)));
  return -sqrt(d.x)*sign(d.y);
}

fn sdf_para(p_in: vec2f, wi: f32, he: f32, sk: f32) -> f32 {
  let e = vec2f(sk, he);
  var p = p_in; if (p.y < 0) { p = -p; }
  var w = p - e; w.x -= clamp(w.x, -wi, wi);
  var d = vec2f(dot(w,w), -w.y);
  let s = p.x*e.y - p.y*e.x;
  if (s < 0) { p = -p; }
  var v = p - vec2f(wi, 0); v -= e*clamp(dot(v,e)/dot(e,e), -1.0, 1.0);
  d = min(d, vec2f(dot(v,v), wi*he - abs(s)));
  return sqrt(d.x)*sign(-d.y);
}

// --- Unified piece SDF: square (0), triangles (1-5), parallelogram (6) ---
fn piece_sdf(p: vec2f, id: u32, tf: vec3f) -> f32 {
  let q = R(p - tf.xy, tf.z);
  switch id {
    case 0u: { return sdf_box(R(q - vec2f(.501, 0), pi*.25), vec2f(.3535)); }
    case 6u: { return sdf_para(q - vec2f(-.25, -.75), .5, .25, .25); }
    default: {
      let i = (id - 1u) * 3u;
      return sdf_tri(q, TV[i], TV[i+1], TV[i+2]);
    }
  }
}

struct Hit { d: f32, col: vec3f }

// --- Scene SDF: evaluate all 7 pieces ---
// Scene transform baked in: rotate PI, scale ±0.35 (y-flip)
fn scene(uv: vec2f, tf: array<vec3f, 7>) -> Hit {
  var r = Hit(1e10, vec3f(0));
  let q = uv * vec2f(1, -1) / .35;
  for (var i = 0u; i < 7u; i++) {
    let d = piece_sdf(q, i, tf[i]) * .35;
    if (d < r.d) { r.d = d; r.col = COL[i]; }
  }
  return r;
}

// --- Opened state: raw data from original (only opened1 is used) ---
// Stored as compact vec3f(x, y, turns), scaled at runtime: pos*4, angle*2*pi
const OPEN = array<vec3f, 7>(
  vec3f(-.25, 0, -pi*.25),
  vec3f(0, .8, -.18),
  vec3f(-.8, .3, -.18),
  vec3f(.6, -.6, .33),
  vec3f(.5, .2, .1),
  vec3f(-.83, -.2, -.22),
  vec3f(-.6, -.5, .15)
);

fn opened_pos(pc: u32) -> vec3f {
  let r = OPEN[pc];
  return vec3f(r.xy * 4, r.z * 2 * pi);
}

// --- Animation: closed -> opened -> cat -> cat -> opened -> closed ---
fn anim_tf(pc: u32, shape: u32, t: f32) -> vec3f {
  let cat = CATS[shape * 7 + pc];
  let open = opened_pos(pc);
  // s: scatter amount (0→1 in, 1→0 out)
  // e: assemble amount (0→1 in, 1→0 out)
  let s = smoothstep(0, .2, t) * (1 - smoothstep(.8, 1, t));
  let e = smoothstep(.2, .45, t) * (1 - smoothstep(.55, .8, t));
  return mix(open * s, cat, e);
}

// --- Bayer 4x4 dither ---
fn bayer(p: vec2u) -> f32 {
  let m = array<f32,16>(0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5);
  return m[(p.x % 4u) + (p.y % 4u) * 4u] / 16.0;
}

// --- Background gradient ---
fn bg(uv: vec2f, t: f32, b: f32) -> vec3f {
  let r = 1 - smoothstep(0.0, 2.5, length(uv));
  let w = (sin(uv.x*8+t*3)*sin(uv.y*8-t*2) + sin(uv.x*12-t*1.5)*cos(uv.y*6+t*2.5)*.5)*.5+.5;
  var c = mix(vec3f(.5,.35,.5), vec3f(1,.85,.7), r*.8 + w*.2);
  c = mix(c, vec3f(.9,.5,.3), w*r*.3);
  return c + vec3f(.15) * pow(1-fract(b),3.);
}

// --- Beat ring ---
fn ring(uv: vec2f, b: f32, pc: vec2u) -> vec3f {
  let f = fract(b);
  let i = smoothstep(.15, 0.0, abs(length(uv) - f*3)) * (1 - f);
  return vec3f(.2,.9,.8) * step(bayer(pc), i);
}

// --- Vertex ---

struct VO {
  @builtin(position) pos: vec4f,
  @location(0) cuv: vec2f,
  @location(1) bt: f32,
  @location(2) @interpolate(flat) t0: vec3f,
  @location(3) @interpolate(flat) t1: vec3f,
  @location(4) @interpolate(flat) t2: vec3f,
  @location(5) @interpolate(flat) t3: vec3f,
  @location(6) @interpolate(flat) t4: vec3f,
  @location(7) @interpolate(flat) t5: vec3f,
  @location(8) @interpolate(flat) t6: vec3f,
}

@vertex fn vs(@builtin(vertex_index) vi: u32) -> VO {
  let xy = array(vec2f(-1,-1), vec2f(-1,3), vec2f(3,-1))[vi];
  var o: VO;
  o.pos = vec4f(xy, 0, 1);
  // Aspect-corrected UV
  let uv = xy * vec2f(.5, -.5) + .5;
  let m = min(u.w, u.h);
  o.cuv = (uv * 2 - 1) * vec2f(u.w/m, u.h/m);

  let b = u.t * BS;
  let sh = u32(floor(b / CYC)) % 6u;
  let at = fract(b / CYC);
  o.bt = pow(1-fract(b),3.);

  // Precompute all 7 transforms (runs 3x total, not per-pixel)
  o.t0 = anim_tf(0, sh, at); o.t1 = anim_tf(1, sh, at);
  o.t2 = anim_tf(2, sh, at); o.t3 = anim_tf(3, sh, at);
  o.t4 = anim_tf(4, sh, at); o.t5 = anim_tf(5, sh, at);
  o.t6 = anim_tf(6, sh, at);
  return o;
}

// --- Fragment ---

@fragment fn fs(i: VO) -> @location(0) vec4f {
  let b = u.t * BS;
  let pc = vec2u(i.pos.xy);
  let tf = array(i.t0, i.t1, i.t2, i.t3, i.t4, i.t5, i.t6);

  // Pixelate UV
  let pix = (floor(i.cuv * 400) + .5) / 400;
  let h = scene(pix, tf);
  let neon = vec3f(1, .2, .6);

  // Mode: vibrant (0) / dark neon (1) — toggles every 2 shape cycles
  let mode = step(2.0, floor(b / 8) % 4);

  // Background (vibrant) or dark flat
  var col = mix(bg(pix, u.t, b), vec3f(.1, .1, .12), mode);

  // Beat ring (vibrant mode only)
  col += ring(i.cuv, b, pc) * (1 - mode);

  // Dark shadow
  let sm = smoothstep(-.05,.05,scene(pix-vec2f(.04,-.04),tf).d);
  col = mix(mix(col, vec3f(0, 0, .15), .5), col, sm);

  // Mode-specific glow
  if (mode < .5) {
    // Vibrant: dithered outline glow
    if (h.d > 0) {
      col += neon * step(bayer(pc), smoothstep(.15, 0.0, h.d) * .6);
    }
  } else {
    // Neon: bouncing pink shadow
    let bb = i.bt;
    let psm = smoothstep(-(.04+bb*.04),.04+bb*.04,scene(pix-vec2f(-.06,.06)*(.5+bb*1.5),tf).d);
    col += neon * step(bayer(pc), (1 - psm) * .8);
  }

  // Fill with halftone
  if (h.d < 0) {
    col = h.col + vec3f(.05) * sin(pix.x*120) * sin(pix.y*120);
  }

  return vec4f(col, 1);
}
