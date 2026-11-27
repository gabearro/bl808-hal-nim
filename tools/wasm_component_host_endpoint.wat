(component
  (type $stream (stream))
  (core func $read (canon stream.read $stream async))
  (core module $m
    (import "" "r" (func $read (param i32 i32 i32) (result i32)))
    (func (export "run") (param $reader i32) (result i32)
      (if (i32.ne (call $read (local.get $reader) (i32.const -1) (i32.const 1))
                  (i32.const 0x10)) (then unreachable))
      (if (i32.ne (call $read (local.get $reader) (i32.const -1) (i32.const 2))
                  (i32.const 0x20)) (then unreachable))
      (i32.const 42)))
  (core instance $m (instantiate $m (with "" (instance (export "r" (func $read))))))
  (func (export "run") (param "reader" $stream) (result u32) (canon lift (core func $m "run"))))
