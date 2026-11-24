(component
  (type $hidden (resource (rep i32)))
  (component $provider
    (import "ticket" (type (sub resource)))
    (core module $code (func (export "run") (result i32) (i32.const 7)))
    (core instance $code (instantiate $code))
    (func (export "run") (result u32) (canon lift (core func $code "run"))))
  (component $carrier
    (import "ticket" (type $Ticket (sub resource)))
    (type $Contract (component
      (alias outer 1 $Ticket (type $T))
      (import "ticket" (type (eq $T)))
      (export "run" (func (result u32)))))
    (import "factory" (component $factory (type $Contract)))
    (export "factory" (component $factory)))
  (instance $carrier (instantiate $carrier (with "factory" (component $provider))
    (with "ticket" (type $hidden))))
  (alias export $carrier "factory" (component $Factory))
  (component $inner
    (alias outer 1 $Factory (component $Private))
    (core module $code (func (export "run") (result i32) (i32.const 42)))
    (core instance $code (instantiate $code))
    (func (export "run") (result u32) (canon lift (core func $code "run"))))
  (export $Opaque "opaque" (component $inner))
  (instance $inner (instantiate $Opaque))
  (func (export "run") (alias export $inner "run")))
