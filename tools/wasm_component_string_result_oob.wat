(module
  (memory (export "cm32p2_memory") 1)
  (func (export "cm32p2||greet") (result i32)
    i32.const 256
    i32.const 65534
    i32.store
    i32.const 260
    i32.const 11
    i32.store
    i32.const 256)
)
