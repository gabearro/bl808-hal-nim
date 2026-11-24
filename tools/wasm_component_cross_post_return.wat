(component
  (component $provider
    (core module $payload
      (memory (export "memory") 1)
      (data (i32.const 8) "\20\00\00\00\01\00\00\00")
      (data (i32.const 32) "*")
      (func (export "text") (result i32) i32.const 8)
      (func (export "post") (param i32)
        (i32.store8 (i32.const 32) (i32.const 0)))
      (func (export "left") (result i32) (i32.load8_u (i32.const 32))))
    (core instance $payload (instantiate $payload))
    (func (export "text") (result string)
      (canon lift (core func $payload "text") (memory (core memory $payload "memory"))
        (post-return (core func $payload "post"))))
    (func (export "left") (result u32)
      (canon lift (core func $payload "left"))))
  (instance $provider (instantiate $provider))
  (component $relay
    (import "text" (func $text (result string)))
    (export "text" (func $text)))
  (instance $relay (instantiate $relay (with "text" (func $provider "text"))))
  (component $consumer
    (import "text" (func $text (result string)))
    (import "left" (func $left (result u32)))
    (core module $memory
      (memory (export "memory") 1)
      (func (export "alloc") (param i32 i32 i32 i32) (result i32) i32.const 64))
    (core instance $memory (instantiate $memory))
    (core func $text (canon lower (func $text)
      (memory (core memory $memory "memory")) (realloc (core func $memory "alloc"))))
    (core func $left (canon lower (func $left)))
    (core module $caller
      (import "" "text" (func $text (param i32)))
      (import "" "left" (func $left (result i32)))
      (import "" "memory" (memory 1))
      (func (export "run") (result i32)
        (call $text (i32.const 16))
        (if (call $left) (then unreachable))
        (if (i32.ne (i32.load (i32.const 20)) (i32.const 1)) (then unreachable))
        (i32.load8_u (i32.load (i32.const 16)))))
    (core instance $caller (instantiate $caller (with "" (instance
      (export "text" (func $text))
      (export "left" (func $left))
      (export "memory" (memory $memory "memory"))))))
    (func (export "run") (result u32) (canon lift (core func $caller "run"))))
  (instance $consumer (instantiate $consumer
    (with "text" (func $relay "text"))
    (with "left" (func $provider "left"))))
  (export "run" (func $consumer "run")))
