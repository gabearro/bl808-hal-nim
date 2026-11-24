(module
  (memory (export "cm32p2_memory") 1)
  (func (export "cm32p2||make-invalid") (result i32)
    i32.const 256
    i32.const 15
    i32.store8
    i32.const 256)
)
