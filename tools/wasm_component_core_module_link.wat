(component
  (core module $engine
    (import "inputs" "b" (func $b (result i32)))
    (import "inputs" "a" (func $a (result i32)))
    (func (export "decoy") (result i32) (i32.const -1))
    (func (export "calc") (result i32)
      (i32.add (i32.mul (call $a) (i32.const 2)) (call $b))))

  (component $provider
    (import "engine" (core module $engine
      (import "inputs" "a" (func (result i32)))
      (import "inputs" "b" (func (result i32)))
      (import "inputs" "unused" (func (result i32)))
      (export "calc" (func (result i32)))))
    (core module $extra)
    (export "extra" (core module $extra))
    (export "runtime" (core module $engine)))

  (component $relay
    (core type $engine-type (module
      (import "inputs" "a" (func (result i32)))
      (import "inputs" "b" (func (result i32)))
      (export "calc" (func (result i32)))))
    (core type $runtime-type (module
      (import "inputs" "unused" (func (result i32)))
      (import "inputs" "a" (func (result i32)))
      (import "inputs" "b" (func (result i32)))
      (export "calc" (func (result i32)))))
    (import "factory" (component $factory
      (alias outer 1 $engine-type (core type $M))
      (alias outer 1 $runtime-type (core type $R))
      (import "engine" (core module (type $M)))
      (export "runtime" (core module (type $R)))))
    (import "engine" (core module $engine (type $engine-type)))
    (instance $made (instantiate $factory (with "engine" (core module $engine))))
    (alias export $made "runtime" (core module $runtime))
    (export "runtime" (core module $runtime) (core module (type $runtime-type))))

  (instance $resolved (instantiate $relay
    (with "factory" (component $provider))
    (with "engine" (core module $engine))))
  (alias export $resolved "runtime" (core module $runtime))
  (core module $inputs
    (func (export "unused") (result i32) unreachable)
    (func (export "a") (result i32) (i32.const 19))
    (func (export "b") (result i32) (i32.const 4)))
  (core instance $inputs (instantiate $inputs))
  (core instance $computed (instantiate $runtime (with "inputs" (instance $inputs))))
  (core module $adapter
    (import "" "calc" (func $calc (result i32)))
    (func (export "run") (result i32) (call $calc)))
  (core instance $adapter (instantiate $adapter (with "" (instance $computed))))
  (func (export "run") (result u32) (canon lift (core func $adapter "run"))))
