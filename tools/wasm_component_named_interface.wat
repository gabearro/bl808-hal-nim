(module
  (import "ox64:demo/bias@0.2.0" "offset" (func $offset (param i32) (result i32)))
  (func (export "ox64:demo/arithmetic@0.2.0#add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add
    call $offset))
