// Stage 1: reset the atomic counters, the indirect args and the vertex-id map
// before the frame's mesh is regenerated. Byte-identical in both documents.

@group(0) @binding(0) var<storage, read_write> counters: array<atomic<u32>, 4>;
@group(0) @binding(1) var<storage, read_write> indirect: array<u32, 5>;
@group(0) @binding(2) var<storage, read_write> vidMap: array<atomic<u32>>;

@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) gid: vec3u) {
  let id = gid.x;
  // Clear atomic counters and indirect draw buffer
  if (id == 0u) {
    atomicStore(&counters[0], 0u); // vertex count
    atomicStore(&counters[1], 0u); // index count
    atomicStore(&counters[2], 0u);
    atomicStore(&counters[3], 0u);
    indirect[0] = 0u; // indexCount
    indirect[1] = 1u; // instanceCount
    indirect[2] = 0u; // firstIndex
    indirect[3] = 0u; // baseVertex
    indirect[4] = 0u; // firstInstance
  }
  // Clear vertex ID map
  if (id < 98304u) {
    atomicStore(&vidMap[id], 0xFFFFFFFFu);
  }
}
