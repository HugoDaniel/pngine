;; A `gen` data WASM that exports its memory as `m` rather than `memory`.
;; The runtime reads a generated buffer through `exports.memory` (or the
;; `env.memory` import it supplied), so this module runs `gen`, writes its
;; bytes, and hands back a memory nobody looks at — a black canvas with no
;; diagnostic. examples/invalid/wasm_gen_memory_name.sjon exists to reject it.
;; Rebuild: wat2wasm examples/invalid/gen_memory_misnamed.wat -o examples/invalid/gen_memory_misnamed.wasm
(module
  (memory (export "m") 1)
  (global (export "l") i32 (i32.const 12))
  (global (export "s") i32 (i32.const 0))
  (func (export "gen") (result i32)
    (f32.store (i32.const 0) (f32.const 1))
    (i32.const 0))
)
