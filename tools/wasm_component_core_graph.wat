(component
  (core module $state
    (type $unary (func (param i32) (result i32)))
    (memory (export "memory") 1 1)
    (table (export "table") 1 1 funcref)
    (global $total (export "total") (mut i32) (i32.const 0))
    (func (export "bump") (type $unary)
      global.get $total
      local.get 0
      i32.add
      global.set $total
      global.get $total)
    (func (export "run") (type $unary)
      local.get 0
      i32.const 0
      call_indirect (type $unary))
    (func (export "read") (result i32)
      i32.const 0
      i32.load))
  (core instance $state (instantiate $state))

  (core module $driver
    (import "env" "memory" (memory 1 2))
    (import "env" "total" (global $total (mut i32)))
    (import "env" "table" (table 1 1 funcref))
    (import "env" "bump" (func $bump (param i32) (result i32)))
    (import "env" "run" (func $run (param i32) (result i32)))
    (elem (i32.const 0) func $bump)
    (func (export "step") (param i32) (result i32)
      i32.const 0
      local.get 0
      call $run
      i32.store
      global.get $total
      i32.const 0
      i32.load
      i32.add))
  (core instance $driver (instantiate $driver (with "env" (instance $state))))
  (alias core export $driver "step" (core func $step))
  (alias core export $state "read" (core func $read))
  (func $increment (param "value" s32) (result s32) (canon lift (core func $step)))
  (func $read (result s32) (canon lift (core func $read)))
  (export "increment" (func $increment))
  (export "read" (func $read)))
