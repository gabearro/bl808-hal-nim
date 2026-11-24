(component
  (type $ticket (resource (rep i32)))
  (export $Ticket "ticket" (type $ticket))
  (type $Contract (component
    (alias outer 1 $Ticket (type $T))
    (import "ticket" (type (eq $T)))))
  (component $provider
    (import "ticket" (type (sub resource))))
  (export $Typed "typed" (component $provider) (component (type $Contract)))
  (component $relay
    (alias outer 1 $Typed (component $Factory))
    (export "factory" (component $Factory)))
  (instance $relay (instantiate $relay))
  (alias export $relay "factory" (component $factory))
  (instance (instantiate $factory (with "ticket" (type $Ticket))))
  (core module $code (func (export "run") (result i32) (i32.const 42)))
  (core instance $code (instantiate $code))
  (func (export "run") (result u32) (canon lift (core func $code "run"))))
