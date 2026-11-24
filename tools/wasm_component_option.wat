(module
  (memory (export "cm32p2_memory") 1)
  (func (export "cm32p2||choose") (param i32 i32) (result i32)
    local.get 0
    if (result i32)
      local.get 1
      i32.const 1
      i32.add
    else
      i32.const 0
    end)
  (func (export "cm32p2||make-option") (param i32) (result i32)
    i32.const 256
    i32.const 1
    i32.store8
    i32.const 260
    local.get 0
    i32.store
    i32.const 256)
)
