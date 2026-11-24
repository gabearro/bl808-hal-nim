(component
  (type $unused (resource (rep i32)))
  (component $source
    (type $Ticket (resource (rep i32)))
    (export "ticket" (type $Ticket)))
  (instance $source (instantiate $source))
  (export $Ticket "ticket" (type $source "ticket"))

  (type $Contract (component
    (alias outer 1 $Ticket (type $Token))
    (import "ticket" (type (eq $Token)))
    (export "run" (func (result u32)))))
  (component $provider
    (import "ticket" (type (sub resource)))
    (core module $entry (func (export "run") (result i32) (i32.const 42)))
    (core instance $entry (instantiate $entry))
    (func (export "run") (result u32) (canon lift (core func $entry "run"))))
  (export $Typed "typed" (component $provider) (component (type $Contract)))
  (component $outer
    (component $inner
      (alias outer 2 $Typed (component $Factory))
      (export "factory" (component $Factory)))
    (instance $inner (instantiate $inner))
    (export "factory" (component $inner "factory")))
  (instance $outer (instantiate $outer))
  (alias export $outer "factory" (component $Factory))
  (instance $worker (instantiate $Factory (with "ticket" (type $Ticket))))
  (func (export "run") (alias export $worker "run")))
