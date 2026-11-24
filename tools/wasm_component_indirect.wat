(module
  (memory (export "cm32p2_memory") 1)
  (func (export "cm32p2_realloc") (param i32 i32 i32 i32) (result i32)
    (if (i32.ne (local.get 2) (i32.const 8)) (then unreachable))
    (if (i32.ne (local.get 3) (i32.const 80)) (then unreachable))
    i32.const 248)
  (func (export "cm32p2||evaluate") (param $args i32) (result i32)
    i32.const 240
    (i64.add (i64.load offset=8 (local.get $args))
      (i64.extend_i32_s (i32.load16_s offset=16 (local.get $args))))
    i64.store
    i32.const 248
    (i32.add (i32.load8_u (local.get $args)) (i32.load offset=72 (local.get $args)))
    i32.store
    i32.const 240))
