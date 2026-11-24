(module
  (memory (export "cm32p2_memory") 1)
  (func (export "cm32p2_realloc") (param i32 i32 i32 i32) (result i32)
    i32.const 384)
  (func (export "cm32p2||len") (param i32 i32 i32) (result i32)
    local.get 2)
  (func (export "cm32p2||get") (result i32)
    i32.const 256
    i32.const 1
    i32.store
    i32.const 260
    i32.const 65535
    i32.store
    i32.const 264
    i32.const 4
    i32.store
    i32.const 256)
)
