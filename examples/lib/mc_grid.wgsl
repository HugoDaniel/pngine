// The marching-cubes grid: 32^3 cells over 33^3 samples, and the corner
// offsets that name a cell's eight samples.
//
// `densityAt` reads a `density` array this file does not declare — a HOLE over
// a VARIABLE, which is what lets one function serve roots that bind the same
// buffer differently: the vertex generator and the index generator bind it
// `read`, the density pass binds it `read_write`. A fragment that declared the
// binding itself could serve only one of them.

const N: u32 = 32u;
const NV: u32 = 33u;

fn densityAt(x: u32, y: u32, z: u32) -> f32 {
  return density[z * NV * NV + y * NV + x];
}

// Corner offsets for 8 cube vertices
const kCorner = array<vec3u, 8>(
  vec3u(0,0,0), vec3u(1,0,0), vec3u(1,1,0), vec3u(0,1,0),
  vec3u(0,0,1), vec3u(1,0,1), vec3u(1,1,1), vec3u(0,1,1)
);
