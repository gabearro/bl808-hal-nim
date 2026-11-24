(module
  (func $plus-one (param i32) (result i32)
    local.get 0
    i32.const 1
    i32.add)
  (func (export "run") (result i32)
    i32.const 41
    call $plus-one))
