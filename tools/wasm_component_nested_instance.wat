(component
  (component $provider
    (type $ticket (resource (rep i32)))
    (export $public "ticket" (type $ticket))
    (core func $new (canon resource.new $ticket))
    (core module $code
      (import "" "new" (func $new (param i32) (result i32)))
      (func (export "make") (result i32) (call $new (i32.const 42)))
      (func (export "read") (param i32) (result i32) (local.get 0)))
    (core instance $code (instantiate $code (with "" (instance (export "new" (func $new))))))
    (func $make (result (own $public)) (canon lift (core func $code "make")))
    (func $read (param "value" (borrow $public)) (result u32)
      (canon lift (core func $code "read")))
    (instance $inner
      (export "ticket" (type $public))
      (export "make" (func $make))
      (export "read" (func $read)))
    (instance $outer
      (export "inner" (instance $inner))
      (export "mirror" (instance $inner)))
    (export "api" (instance $outer)))
  (component $consumer
    (import "api" (instance $api
      (export "inner" (instance $inner
        (export "ticket" (type $ticket (sub resource)))
        (export "make" (func (result (own $ticket))))
        (export "read" (func (param "value" (borrow $ticket)) (result u32)))))
      (alias export $inner "ticket" (type $ticket))
      (export "mirror" (instance (export "ticket" (type (eq $ticket)))))))
    (alias export $api "inner" (instance $inner))
    (alias export $api "mirror" (instance $mirror))
    (alias export $mirror "ticket" (type $ticket))
    (core func $make (canon lower (func $inner "make")))
    (core func $read (canon lower (func $inner "read")))
    (core func $drop (canon resource.drop $ticket))
    (core module $code
      (import "" "make" (func $make (result i32)))
      (import "" "read" (func $read (param i32) (result i32)))
      (import "" "drop" (func $drop (param i32)))
      (func (export "run") (result i32) (local $value i32)
        (local.set $value (call $make))
        (call $read (local.get $value))
        (call $drop (local.get $value))))
    (core instance $code (instantiate $code (with "" (instance
      (export "make" (func $make))
      (export "read" (func $read))
      (export "drop" (func $drop))))))
    (func (export "run") (result u32) (canon lift (core func $code "run"))))
  (component $projector
    (import "factory" (component $factory
      (export "api" (instance
        (export "inner" (instance $inner
          (export "ticket" (type $ticket (sub resource)))
          (export "make" (func (result (own $ticket))))
          (export "read" (func (param "value" (borrow $ticket)) (result u32)))))
        (alias export $inner "ticket" (type $ticket))
        (export "mirror" (instance (export "ticket" (type (eq $ticket)))))))))
    (instance $view (instantiate $factory))
    (export "api" (instance $view "api")))
  (instance $provider (instantiate $provider))
  (export "nested" (instance $provider "api"))
  (instance $consumer (instantiate $consumer (with "api" (instance $provider "api"))))
  (instance $projected (instantiate $projector (with "factory" (component $provider))))
  (export "projected" (instance $projected "api"))
  (func (export "run") (alias export $consumer "run")))
