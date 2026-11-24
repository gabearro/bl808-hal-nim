(module
  (import "ox64" "d0-service" (func $service (param i32 i32) (result i32)))
  (func (export "indirect") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    call $service))
