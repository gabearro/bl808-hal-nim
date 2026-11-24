(component
  (import "scale" (func $scale (param "value" u32) (result u32)))
  (import "offset" (func $offset (result u32)))
  (core func $scale-core (canon lower (func $scale)))
  (core func $offset-core (canon lower (func $offset)))
  (core module $code
    (import "" "scale" (func $scale (param i32) (result i32)))
    (import "" "offset" (func $offset (result i32)))
    (func (export "apply") (param i32) (result i32)
      (i32.add (call $scale (local.get 0)) (call $offset))))
  (core instance $instance (instantiate $code (with "" (instance
    (export "offset" (func $offset-core))
    (export "scale" (func $scale-core))))))
  (func (export "apply") (param "value" u32) (result u32)
    (canon lift (core func $instance "apply"))))
