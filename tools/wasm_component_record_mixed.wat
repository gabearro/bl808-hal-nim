(module
  (memory (export "cm32p2_memory") 1)
  (func (export "cm32p2||echo-mixed")
    (param i32 i64 i32 f32) (result i32)
    i32.const 256
    local.get 0
    i32.store8
    i32.const 264
    local.get 1
    i64.store
    i32.const 272
    local.get 2
    i32.store16
    i32.const 276
    local.get 3
    f32.store
    i32.const 256)
)
