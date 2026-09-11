// A test-only fragment whose finding is NOT the unused-declaration rule: the
// local `k` shadows the module-scope one (W0100). Unit tests need a file-backed
// advisory that survives the imported-fragment suppression, and every shipping
// library in here is deliberately clean.

const k = 1.0;

fn shadowing(x: f32) -> f32 {
  let k = 2.0;
  return x + k;
}
