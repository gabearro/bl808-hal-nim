(component
  (core type $engine (module (export "run" (func (result i32)))))
  (import "service" (instance $service
    (export "port" (instance (export "engine" (core module (type $engine)))))))
  (import "engine" (core module $direct (type $engine)))
  (alias export $service "port" (instance $port))
  (alias export $port "engine" (core module $nested))
  (core instance $nested (instantiate $nested))
  (core instance $direct (instantiate $direct))
  (core module $sum
    (import "direct" "run" (func $direct (result i32)))
    (import "nested" "run" (func $nested (result i32)))
    (func (export "run") (result i32)
      (i32.add (i32.mul (call $direct) (i32.const 2)) (call $nested))))
  (core instance $sum (instantiate $sum (with "direct" (instance $direct))
                                         (with "nested" (instance $nested))))
  (func (export "run") (result u32) (canon lift (core func $sum "run"))))
