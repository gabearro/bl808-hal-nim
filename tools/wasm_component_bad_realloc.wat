(module
  (memory (export "cm32p2_memory") 1)
  (func (export "cm32p2_realloc") (param i32 i32 i32 i32) (result i32)
    i32.const 65535)
  (func (export "cm32p2||first-byte") (param i32 i32) (result i32)
    local.get 0
    i32.load8_u)
)
