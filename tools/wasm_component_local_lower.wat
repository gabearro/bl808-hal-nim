(component
  (core module $callee
    (global $count (mut i32) (i32.const 0))
    (func (export "target") (param i32) (result i32)
      (if (i32.ne (local.get 0) (i32.const 1)) (then unreachable))
      (global.set $count (i32.add (global.get $count) (i32.const 1)))
      (global.get $count)))
  (core instance $callee (instantiate $callee))
  (func $lift (param "enabled" bool) (result u32)
    (canon lift (core func $callee "target")))
  (core func $lower (canon lower (func $lift)))
  (core module $caller
    (import "" "call" (func $call (param i32) (result i32)))
    (func $start
      (if (i32.ne (call $call (i32.const 2)) (i32.const 1)) (then unreachable)))
    (start $start)
    (func (export "run") (result i32)
      (i32.add (call $call (i32.const 2)) (i32.const 40))))
  (core instance $caller (instantiate $caller
    (with "" (instance (export "call" (func $lower))))))
  (func (export "run") (result u32) (canon lift (core func $caller "run"))))
