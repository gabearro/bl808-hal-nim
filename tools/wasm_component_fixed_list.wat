(module
  (memory (export "memory") 1 1)

  (func (export "single") (param i64) (result i64)
    local.get 0)

  (func (export "reverse") (param i32 i32 i32) (result i32)
    i32.const 128
    local.get 2
    i32.store
    i32.const 128
    local.get 1
    i32.store offset=4
    i32.const 128
    local.get 0
    i32.store offset=8
    i32.const 128))
