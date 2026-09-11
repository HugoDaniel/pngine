// The integer hash the corpus seeds with: a multiply-xorshift bit mix scaled to
// [0, 1). 18 copies across 15 documents collapsed here (§398). It binds nothing
// and declares no entry point, so one file serves every document that wants a
// deterministic per-index random. examples/samples/ keeps its own copies — a
// `:file` path cannot climb out of the document's own directory.

fn hash(n: u32) -> f32 {
  var x = n;
  x = ((x >> 16u) ^ x) * 0x45d9f3bu;
  x = ((x >> 16u) ^ x) * 0x45d9f3bu;
  x = (x >> 16u) ^ x;
  return f32(x) / f32(0xffffffffu);
}
