(component
  (component $provider
    (import "inputs" (instance $inputs
      (export "beta" (instance (export "get" (func (result u32)))))
      (export "alpha" (instance (export "get" (func (result u32)))))))
    (alias export $inputs "alpha" (instance $alpha))
    (alias export $inputs "beta" (instance $beta))
    (core func $a (canon lower (func $alpha "get")))
    (core func $b (canon lower (func $beta "get")))
    (core module $code
      (import "" "a" (func $a (result i32)))
      (import "" "b" (func $b (result i32)))
      (func (export "run") (result i32)
        (i32.add (i32.mul (call $a) (i32.const 2)) (call $b)))
      (func (export "extra") (result i32) (i32.const 0)))
    (core instance $code (instantiate $code (with "" (instance
      (export "a" (func $a)) (export "b" (func $b))))))
    (func $run (result u32) (canon lift (core func $code "run")))
    (func $extra (result u32) (canon lift (core func $code "extra")))
    (instance $other (export "extra" (func $extra)))
    (instance $methods (export "extra" (func $extra)) (export "run" (func $run)))
    (instance $api (export "other" (instance $other)) (export "methods" (instance $methods)))
    (export "api" (instance $api)))
  (component $consumer
    (import "factory" (component $factory
      (import "inputs" (instance
        (export "alpha" (instance (export "get" (func (result u32)))))
        (export "ignored" (instance))
        (export "beta" (instance (export "get" (func (result u32)))))))
      (export "api" (instance (export "methods" (instance
        (export "run" (func (result u32)))))))))
    (import "inputs" (instance $inputs
      (export "alpha" (instance (export "get" (func (result u32)))))
      (export "ignored" (instance))
      (export "beta" (instance (export "get" (func (result u32)))))))
    (instance $linked (instantiate $factory (with "inputs" (instance $inputs))))
    (alias export $linked "api" (instance $api))
    (alias export $api "methods" (instance $methods))
    (func (export "run") (alias export $methods "run")))
  (core module $source
    (func (export "a") (result i32) (i32.const 19))
    (func (export "b") (result i32) (i32.const 4)))
  (core instance $source (instantiate $source))
  (func $a (result u32) (canon lift (core func $source "a")))
  (func $b (result u32) (canon lift (core func $source "b")))
  (instance $alpha (export "get" (func $a)))
  (instance $beta (export "get" (func $b)))
  (instance $ignored)
  (instance $inputs
    (export "ignored" (instance $ignored))
    (export "beta" (instance $beta))
    (export "alpha" (instance $alpha)))
  (instance $consumer (instantiate $consumer
    (with "factory" (component $provider)) (with "inputs" (instance $inputs))))
  (func (export "run") (alias export $consumer "run")))
