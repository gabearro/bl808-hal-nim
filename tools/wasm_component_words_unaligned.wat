(module
  (memory (export "cm32p2_memory") 1)
  (func (export "cm32p2_realloc") (param i32 i32 i32 i32) (result i32)
    i32.const 385)
  (func (export "cm32p2||echo-words") (param i32 i32) (result i32)
    i32.const 256
    local.get 0
    i32.store
    i32.const 260
    local.get 1
    i32.store
    i32.const 256)
)
