// Stage 5: turn the atomic index counter into a GPUDrawIndexedIndirectArgs
// block for `(draw-indexed-indirect …)`, clamped to the index buffer's size.
// Byte-identical in both documents, so it is one file rather than two.

@group(0) @binding(0) var<storage, read_write> counters: array<atomic<u32>, 4>;
@group(0) @binding(1) var<storage, read_write> indirect: array<u32, 5>;

@compute @workgroup_size(1)
fn main() {
  indirect[0] = min(atomicLoad(&counters[1]), 262144u); // indexCount
  indirect[1] = 1u; // instanceCount
  indirect[2] = 0u; // firstIndex
  indirect[3] = 0u; // baseVertex
  indirect[4] = 0u; // firstInstance
}
