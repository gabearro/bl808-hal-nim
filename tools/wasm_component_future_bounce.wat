(module
  (memory (export "memory") 1)
  (func (export "bounce") (param i32) (result i32)
    local.get 0)
  (func (export "tagged-bounce") (param i32 i32) (result i32)
    (i32.store (i32.const 0) (local.get 0))
    (i32.store (i32.const 4) (local.get 1))
    (i32.const 0)))
