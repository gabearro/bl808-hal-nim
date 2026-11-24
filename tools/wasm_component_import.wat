(module
  (import "cm32p2" "scale" (func $scale (param i32) (result i32)))
  (func (export "cm32p2||adjusted") (param i32) (result i32)
    local.get 0
    call $scale
    i32.const 2
    i32.add)
)
