(component
  (type $Rich (instance
    (export "read" (func (result u32)))
    (export "extra" (func))))
  (type $Narrow (instance (export "read" (func (result u32)))))
  (export $public "shape" (type $Rich) (type (eq $Narrow)))
  (instance $box (export "shape" (type $public)))
  (alias export $box "shape" (type $Alias))
  (component $worker
    (type $Required (instance (export "read" (func (result u32)))))
    (import "shape" (type (eq $Required)))
    (core module $code (func (export "run") (result i32) (i32.const 42)))
    (core instance $code (instantiate $code))
    (func (export "run") (result u32) (canon lift (core func $code "run"))))
  (instance $worker (instantiate $worker (with "shape" (type $Alias))))
  (func (export "run") (alias export $worker "run")))
