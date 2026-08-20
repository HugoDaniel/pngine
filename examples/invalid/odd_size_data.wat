;; Data WASM whose `l` export is 6 -- deliberately NOT a multiple of 4, which
;; is what examples/invalid/wasm_data_size_unaligned.sjon exists to reject.
;; Rebuild: wat2wasm examples/invalid/odd_size_data.wat -o examples/invalid/odd_size_data.wasm
(module
  (memory (export "m") 1)
  (data (i32.const 0) "\01\02\03\04\05\06")
  (global (export "l") i32 (i32.const 6))
  (global (export "s") i32 (i32.const 0))
)
