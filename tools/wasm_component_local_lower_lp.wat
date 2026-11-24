(component
  (core module $callee
    (func (export "identity") (param i32) (result i32) local.get 0))
  (core instance $callee (instantiate $callee))
  (func $lift (param "enabled" bool) (result u32)
    (canon lift (core func $callee "identity")))
  (core func $lower (canon lower (func $lift)))
  (core module $caller
    (import "" "call" (func $call (param i32) (result i32)))
    (func (export "run") (result i32)
      (i32.add (call $call (i32.const 2)) (i32.const 41))))
  (core instance $caller (instantiate $caller
    (with "" (instance (export "call" (func $lower))))))
  (func (export "run") (result u32) (canon lift (core func $caller "run"))))
