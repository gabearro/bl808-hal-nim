(module
  (global $value (mut i32) (i32.const 0))
  (func $start
    i32.const 42
    global.set $value)
  (start $start)
  (func (export "run") (result i32)
    global.get $value))
