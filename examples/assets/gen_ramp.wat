;; gen_ramp — a data WASM that COMPUTES its bytes instead of storing them.
;;
;; A `(buffer :file …)` reads `l` (byte length) and `s` (where the bytes live in
;; this module's memory). Export a `gen` function beside them and the split
;; changes hands: the module is shipped whole, the runtime calls `gen` once when
;; the buffer is created, and `gen` RETURNS the pointer the bytes were written
;; to. Without `gen` the compiler reads the data segments itself and ships the
;; bytes alone (examples/test_data.wat).
;;
;; There is deliberately no data segment here: read statically this module is
;; twelve zero bytes, so a black canvas means `gen` never ran. `s` is 16 rather
;; than 0 so the fixture also pins WHICH offset each side owns — `s` addresses
;; this module's memory, never the GPU buffer, which is exactly `l` bytes long
;; and is always written from 0.
;;
;; The memory is exported as `memory`, not `m`. A module the RUNTIME executes is
;; read through `exports.memory` (or the `env.memory` it was handed as an
;; import), so any other spelling hands `gen` a memory nobody reads —
;; assets/mvp.wasm and assets/cube.wasm both export `memory` for the same
;; reason. `m` survives in test_data.wat only because nothing instantiates it:
;; a module with no `gen` is read by the COMPILER, out of its data segments.
(module
  (memory (export "memory") 1)
  (global (export "l") i32 (i32.const 12))
  (global (export "s") i32 (i32.const 16))

  ;; ramp[i] = i * 0.5 → (0.0, 0.5, 1.0), an azure the eye cannot mistake for
  ;; the orange of test_data.wat or for the zeros of a `gen` that never ran.
  (func (export "gen") (result i32)
    (local $i i32)
    (loop $next
      (f32.store
        (i32.add (global.get 1) (i32.mul (local.get $i) (i32.const 4)))
        (f32.mul (f32.convert_i32_s (local.get $i)) (f32.const 0.5)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $next (i32.lt_s (local.get $i) (i32.const 3))))
    (global.get 1))
)
