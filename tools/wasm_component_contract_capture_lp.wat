(component
  (type $ticket (resource (rep i32)))
  (export $Ticket "ticket" (type $ticket))
  (type $Contract (component
    (alias outer 1 $Ticket (type $Captured))
    (import "ticket" (type (eq $Captured)))
    (export "run" (func (result u32)))))
  (component $provider
    (import "ticket" (type (sub resource)))
    (core module $code (func (export "run") (result i32) (i32.const 42)))
    (core instance $code (instantiate $code))
    (func (export "run") (result u32) (canon lift (core func $code "run"))))
  (export $Typed "provider" (component $provider) (component (type $Contract)))
  (instance $worker (instantiate $Typed (with "ticket" (type $Ticket))))
  (func (export "run") (alias export $worker "run")))
