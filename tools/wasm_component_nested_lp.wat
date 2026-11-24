(component
  (component $callee
    (core module $module
      (func (export "check") (param i32)
        local.get 0
        i32.const 1
        i32.ne
        if unreachable end))
    (core instance $code (instantiate $module))
    (func (export "check") (param "value" bool)
      (canon lift (core func $code "check"))))
  (instance $callee-instance (instantiate $callee))
  (core func $call (canon lower (func $callee-instance "check")))
  (core module $module
    (import "" "check" (func $check (param i32)))
    (func (export "run") (result i32)
      i32.const 2
      call $check
      i32.const 43))
  (core instance $code (instantiate $module
    (with "" (instance (export "check" (func $call))))))
  (func (export "run") (result u32)
    (canon lift (core func $code "run"))))
