;; Test data WASM: 3 floats (RGB color) = 12 bytes
;; Color: (1.0, 0.5, 0.0) = orange
(module
  (memory (export "m") 1)
  (data (i32.const 0)
    "\00\00\80\3f"  ;; 1.0 as f32 LE
    "\00\00\00\3f"  ;; 0.5 as f32 LE
    "\00\00\00\00"  ;; 0.0 as f32 LE
  )
  (global (export "l") i32 (i32.const 12))
  (global (export "s") i32 (i32.const 0))
)
