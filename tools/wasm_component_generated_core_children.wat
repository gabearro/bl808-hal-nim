(component
  (component $provider
    (core module $module (func (export "answer") (result i32) i32.const 42))
    (core instance $instance (instantiate $module))
    (func (export "answer") (result u32)
      (canon lift (core func $instance "answer"))))
  (instance $provider (instantiate $provider))
  (alias export $provider "answer" (func $answer))
  (core func $lower (canon lower (func $answer)))
  (func $lift (result u32) (canon lift (core func $lower)))
  (component $consumer
    (import "answer" (func $answer (result u32)))
    (core func $answer (canon lower (func $answer)))
    (core module $module
      (import "" "answer" (func $answer (result i32)))
      (global $result (mut i32) (i32.const 0))
      (func $start (global.set $result (call $answer)))
      (start $start)
      (func (export "run") (result i32) global.get $result))
    (core instance $instance (instantiate $module
      (with "" (instance (export "answer" (func $answer))))))
    (func (export "run") (result u32) (canon lift (core func $instance "run"))))
  (instance $consumer (instantiate $consumer (with "answer" (func $lift))))
  (export "run" (func $consumer "run")))
