(module
  (memory (export "cm32p2_memory") 1)
  (func (export "cm32p2||inspect") (param i32 i64) (result i64)
    local.get 1)
  (func (export "cm32p2||make-error") (param i64) (result i32)
    i32.const 256
    i32.const 1
    i32.store8
    i32.const 264
    local.get 0
    i64.store
    i32.const 256)
)
