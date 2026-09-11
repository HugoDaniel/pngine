// Stage 3: for every cell that straddles the isosurface, emit one vertex per
// crossed primary edge, with its normal and ambient occlusion, and record its
// id so stage 4 can index it.
//
// Byte-identical in both documents. Imports ./mc_inputs.wgsl, ./mc_grid.wgsl,
// ./mc_normal.wgsl and the document's field instance.

@group(0) @binding(0) var<storage, read> density: array<f32>;
@group(0) @binding(1) var<storage, read_write> vertices: array<f32>;
@group(0) @binding(2) var<storage, read_write> vidMap: array<atomic<u32>>;
@group(0) @binding(3) var<storage, read_write> counters: array<atomic<u32>, 4>;
@group(0) @binding(4) var<uniform> pngine: PngineInputs;

const GRID_MIN: f32 = -16.0;
const CELL_SIZE: f32 = 1.0;

// Primary edge definitions: (corner0, corner1, axis)
// Edge 0: X-axis (corners 0→1), Edge 3: Y-axis (corners 0→3), Edge 8: Z-axis (corners 0→4)
const kPrimaryEdge = array<vec3u, 3>(
  vec3u(0u, 1u, 0u), // edge 0: X
  vec3u(0u, 3u, 1u), // edge 3: Y
  vec3u(0u, 4u, 2u)  // edge 8: Z
);

@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) gid: vec3u) {
  let id = gid.x;
  if (id >= 32768u) { return; } // 32^3 cells
  let cz = id / (N * N);
  let cy = (id / N) % N;
  let cx = id % N;

  // Read 8 corner densities
  var d: array<f32, 8>;
  for (var i = 0u; i < 8u; i++) {
    let c = kCorner[i];
    d[i] = densityAt(cx + c.x, cy + c.y, cz + c.z);
  }

  // Compute cube case (standard Paul Bourke convention: bit i = corner i inside)
  var cubeCase = 0u;
  for (var i = 0u; i < 8u; i++) {
    if (d[i] > 0.0) { cubeCase |= (1u << i); }
  }
  if (cubeCase == 0u || cubeCase == 255u) { return; }

  // Check 3 primary edges
  for (var e = 0u; e < 3u; e++) {
    let c0 = kPrimaryEdge[e].x;
    let c1 = kPrimaryEdge[e].y;
    let axis = kPrimaryEdge[e].z;
    let d0 = d[c0];
    let d1 = d[c1];

    // Edge crosses isosurface if signs differ
    if ((d0 < 0.0) == (d1 < 0.0)) { continue; }

    // Interpolate position
    let t = d0 / (d0 - d1);
    let p0 = vec3f(f32(cx) + f32(kCorner[c0].x), f32(cy) + f32(kCorner[c0].y), f32(cz) + f32(kCorner[c0].z));
    let p1 = vec3f(f32(cx) + f32(kCorner[c1].x), f32(cy) + f32(kCorner[c1].y), f32(cz) + f32(kCorner[c1].z));
    let localPos = mix(p0, p1, vec3f(t));
    let worldPos = localPos * CELL_SIZE + vec3f(GRID_MIN);

    // Normal from the shared central difference; ambient occlusion from the
    // document's own field instance, which is where a march that only makes
    // sense for a distance function can live without the other document
    // having to pretend it has one.
    let normal = computeNormal(worldPos);
    let ao = ambientOcclusion(worldPos, normal);

    // Allocate vertex
    let vertexId = atomicAdd(&counters[0], 1u);
    if (vertexId >= 65536u) { continue; }

    // Write vertex data: [pos.x, pos.y, pos.z, ao, normal.x, normal.y, normal.z, 0]
    let base = vertexId * 8u;
    vertices[base + 0u] = worldPos.x;
    vertices[base + 1u] = worldPos.y;
    vertices[base + 2u] = worldPos.z;
    vertices[base + 3u] = ao;
    vertices[base + 4u] = normal.x;
    vertices[base + 5u] = normal.y;
    vertices[base + 6u] = normal.z;
    vertices[base + 7u] = 0.0;

    // Store vertex ID in map
    let mapIdx = axis * N * N * N + cz * N * N + cy * N + cx;
    atomicStore(&vidMap[mapIdx], vertexId);
  }
}
