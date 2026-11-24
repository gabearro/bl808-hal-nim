(component
  (type $Rich (component
    (export "run" (func (result u32)))
    (export "extra" (func))))
  (type $Thin (component (export "run" (func (result u32)))))
  (export $public "shape" (type $Rich) (type (eq $Thin)))
  (instance $box (export "shape" (type $public)))
  (alias export $box "shape" (type $Found))
  (component $worker
    (type $Required (component (export "run" (func (result u32)))))
    (import "schema" (type (eq $Required)))
    (core module $code (func (export "run") (result i32) (i32.const 42)))
    (core instance $code (instantiate $code))
    (func (export "run") (result u32) (canon lift (core func $code "run"))))
  (instance $worker (instantiate $worker (with "schema" (type $Found))))
  (func (export "run") (alias export $worker "run")))
