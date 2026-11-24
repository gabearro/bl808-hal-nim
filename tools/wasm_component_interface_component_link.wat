(component
  (type $Narrow (component (export "run" (func (result u32)))))
  (type $Wide (component
    (export "extra" (func (result u32)))
    (export "run" (func (result u32)))))
  (component $work
    (core module $code
      (global $calls (mut i32) (i32.const 41))
      (func (export "extra") (result i32) (i32.const 0))
      (func (export "run") (result i32)
        (global.set $calls (i32.add (global.get $calls) (i32.const 1)))
        (global.get $calls)))
    (core instance $code (instantiate $code))
    (func (export "run") (result u32) (canon lift (core func $code "run")))
    (func (export "extra") (result u32) (canon lift (core func $code "extra"))))
  (component $other
    (core module $code (func (export "run") (result i32) (i32.const 85)))
    (core instance $code (instantiate $code))
    (func (export "run") (result u32) (canon lift (core func $code "run"))))

  (component $provider
    (import "service" (instance $service
      (export "right" (instance (export "task" (component (type $Narrow)))))
      (export "left" (instance (export "task" (component (type $Narrow)))))))
    (alias export $service "left" (instance $left))
    (alias export $service "right" (instance $right))
    (alias export $left "task" (component $left-task))
    (alias export $right "task" (component $right-task))
    (instance $published-left
      (export "hidden" (component $right-task))
      (export "task" (component $left-task)))
    (instance $published-right (export "task" (component $right-task)))
    (instance $package
      (export "left" (instance $published-left))
      (export "right" (instance $published-right)))
    (export "package" (instance $package)))

  (component $relay
    (type $Incoming (instance
      (export "left" (instance (export "task" (component (type $Wide)))))
      (export "right" (instance (export "task" (component (type $Narrow)))))))
    (type $Outgoing (instance
      (export "right" (instance (export "task" (component (type $Narrow)))))
      (export "left" (instance (export "task" (component (type $Narrow)))))))
    (import "factory" (component $factory
      (import "service" (instance (type $Incoming)))
      (export "package" (instance (type $Outgoing)))))
    (import "service" (instance $service (type $Incoming)))
    (instance $linked (instantiate $factory (with "service" (instance $service))))
    (export "package" (instance $linked "package")))

  (instance $input-left (export "task" (component $work)))
  (instance $input-right (export "task" (component $other)))
  (instance $input
    (export "right" (instance $input-right))
    (export "left" (instance $input-left)))
  (instance $linked (instantiate $relay (with "factory" (component $provider))
    (with "service" (instance $input))))
  (alias export $linked "package" (instance $package))
  (alias export $package "right" (instance $right))
  (alias export $package "left" (instance $left))
  (alias export $right "task" (component $right))
  (alias export $left "task" (component $left))
  (instance $first (instantiate $left))
  (instance $second (instantiate $left))
  (instance $control (instantiate $right))
  (func (export "run") (alias export $first "run"))
  (func (export "run-second") (alias export $second "run"))
  (func (export "run-control") (alias export $control "run")))
