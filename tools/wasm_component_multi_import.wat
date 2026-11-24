(module
  (import "cm32p2" "double" (func $double (param i32) (result i32)))
  (import "cm32p2" "triple" (func $triple (param i32) (result i32)))
  (func (export "cm32p2||combine") (param i32) (result i32)
    local.get 0
    call $double
    local.get 0
    call $triple
    i32.add)
)
