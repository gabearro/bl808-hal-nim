(module
  (memory (export "cm32p2_memory") 1)
  (func (export "cm32p2||describe") (param i32 i64) (result i64)
    local.get 0
    i32.eqz
    if (result i64)
      i64.const 0
    else
      local.get 1
    end)
  (func (export "cm32p2||make-wide") (param i64) (result i32)
    i32.const 256
    i32.const 2
    i32.store8
    i32.const 264
    local.get 0
    i64.store
    i32.const 256)
)
