(component
  (core module $state
    (memory (export "memory") 1 1)
    (func (export "read") (result i32)
      i32.const 0
      i32.load))
  (core instance $state (instantiate $state))
  (core module $worker
    (import "env" "memory" (memory 1 1))
    (import "env" "read" (func $read (result i32)))
    (func (export "increment") (param i32) (result i32)
      i32.const 0
      call $read
      local.get 0
      i32.add
      i32.store
      call $read
      i32.const 2
      i32.mul))
  (core instance $worker (instantiate $worker (with "env" (instance $state))))
  (func (export "read") (result s32) (canon lift (core func $state "read")))
  (func (export "increment") (param "value" s32) (result s32)
    (canon lift (core func $worker "increment"))))
