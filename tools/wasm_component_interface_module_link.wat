(component
  (core module $left
    (import "inputs" "value" (func $value (result i32)))
    (func (export "calc") (result i32) (i32.add (call $value) (i32.const 1)))
    (func (export "decoy") (result i32) (i32.const -1)))
  (core module $right
    (func (export "calc") (result i32) (i32.const 16)))

  (core type $left-tight (module
    (import "inputs" "value" (func (result i32)))
    (export "calc" (func (result i32)))))
  (core type $left-wide (module
    (import "inputs" "unused" (func (result i32)))
    (import "inputs" "value" (func (result i32)))
    (export "calc" (func (result i32)))))
  (core type $right-type (module (export "calc" (func (result i32)))))

  (component $provider
    (import "service" (instance $service
      (export "right" (instance (export "engine" (core module (type $right-type)))))
      (export "left" (instance (export "engine" (core module (type $left-wide)))))))
    (alias export $service "left" (instance $left))
    (alias export $service "right" (instance $right))
    (alias export $left "engine" (core module $left-engine))
    (alias export $right "engine" (core module $right-engine))
    (core module $extra (func (export "calc") (result i32) (i32.const -1)))
    (instance $published-left
      (export "decoy" (core module $extra))
      (export "engine" (core module $left-engine)))
    (instance $published-right (export "engine" (core module $right-engine)))
    (instance $package
      (export "left" (instance $published-left))
      (export "right" (instance $published-right)))
    (export "package" (instance $package)))

  (component $relay
    (type $incoming (instance
      (export "left" (instance (export "engine" (core module (type $left-tight)))))
      (export "right" (instance (export "engine" (core module (type $right-type)))))))
    (type $outgoing (instance
      (export "right" (instance (export "engine" (core module (type $right-type)))))
      (export "left" (instance (export "engine" (core module (type $left-wide)))))))
    (import "factory" (component $factory
      (import "service" (instance (type $incoming)))
      (export "package" (instance (type $outgoing)))))
    (import "service" (instance $service (type $incoming)))
    (instance $linked (instantiate $factory (with "service" (instance $service))))
    (export "package" (instance $linked "package")))

  (instance $incoming-left (export "engine" (core module $left)))
  (instance $incoming-right (export "engine" (core module $right)))
  (instance $incoming
    (export "left" (instance $incoming-left))
    (export "right" (instance $incoming-right)))
  (instance $linked (instantiate $relay (with "factory" (component $provider))
    (with "service" (instance $incoming))))
  (alias export $linked "package" (instance $package))
  (alias export $package "right" (instance $right-output))
  (alias export $package "left" (instance $left-output))
  (alias export $right-output "engine" (core module $right-linked))
  (alias export $left-output "engine" (core module $left-linked))

  (core module $inputs
    (func (export "value") (result i32) (i32.const 12))
    (func (export "unused") (result i32) unreachable))
  (core instance $inputs (instantiate $inputs))
  (core instance $right-run (instantiate $right-linked))
  (core instance $left-run (instantiate $left-linked (with "inputs" (instance $inputs))))
  (core module $sum
    (import "left" "calc" (func $left (result i32)))
    (import "right" "calc" (func $right (result i32)))
    (func (export "run") (result i32)
      (i32.add (i32.mul (call $left) (i32.const 2)) (call $right))))
  (core instance $sum (instantiate $sum (with "left" (instance $left-run))
                                         (with "right" (instance $right-run))))
  (func (export "run") (result u32) (canon lift (core func $sum "run"))))
