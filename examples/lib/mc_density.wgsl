// Stage 2: sample the scalar field at every one of the 33^3 grid points.
//
// This root is byte-identical in both documents, which is the whole point:
// what differs between a marching-cubes SDF and a metaball field is `field`
// itself, and that comes in as an imported instance fragment. The donor
// documents wrote `-sdf(...)` here and `field(...)` there.
//
// Imports ./mc_inputs.wgsl and the document's field instance.

@group(0) @binding(0) var<uniform> pngine: PngineInputs;
@group(0) @binding(1) var<storage, read_write> density: array<f32>;

@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) gid: vec3u) {
  let id = gid.x;
  if (id >= 35937u) { return; } // 33^3
  let N = 33u;
  let z = id / (N * N);
  let y = (id / N) % N;
  let x = id % N;
  let pos = vec3f(f32(x), f32(y), f32(z)) * 1.0 + vec3f(-16.0);
  density[id] = field(pos, pngine.time); // positive = inside, the triangle table's convention
}
