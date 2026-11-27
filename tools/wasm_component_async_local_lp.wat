(component
  (core func $return (canon task.return))
  (core module $callee
    (import "" "return" (func $return))
    (func (export "start") (result i32) (call $return) (i32.const 0))
    (func (export "next") (param i32 i32 i32) (result i32) unreachable))
  (core instance $callee (instantiate $callee (with "" (instance (export "return" (func $return))))))
  (func $task async
    (canon lift (core func $callee "start") async (callback (core func $callee "next"))))
  (core func $lower (canon lower (func $task) async))
  (core func $new (canon waitable-set.new))
  (core func $join (canon waitable.join))
  (core module $caller
    (import "" "lower" (func $lower (result i32)))
    (import "" "new" (func $new (result i32)))
    (import "" "join" (func $join (param i32 i32)))
    (import "" "return" (func $return))
    (func (export "start") (result i32)
      (local $ws i32)
      (local.set $ws (call $new))
      (if (i32.ne (call $lower) (i32.const 0x20)) (then unreachable))
      (call $join (i32.const 2) (local.get $ws))
      (i32.or (i32.shl (local.get $ws) (i32.const 4)) (i32.const 2)))
    (func (export "next") (param $code i32) (param $id i32) (param $state i32) (result i32)
      (if (i32.ne (local.get $code) (i32.const 1)) (then unreachable))
      (if (i32.ne (local.get $id) (i32.const 2)) (then unreachable))
      (if (i32.ne (local.get $state) (i32.const 2)) (then unreachable))
      (call $return) (i32.const 0)))
  (core instance $caller (instantiate $caller (with "" (instance
    (export "lower" (func $lower)) (export "new" (func $new))
    (export "join" (func $join)) (export "return" (func $return))))))
  (func (export "run") async
    (canon lift (core func $caller "start") async (callback (core func $caller "next")))))
