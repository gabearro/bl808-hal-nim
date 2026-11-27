(component
  (core func $parallel (canon thread.available-parallelism))
  (core module $m
    (import "" "p" (func $parallel (result i32)))
    (func (export "run") (result i32) (call $parallel)))
  (core instance $m (instantiate $m (with "" (instance (export "p" (func $parallel))))))
  (func (export "run") (result u32) (canon lift (core func $m "run"))))
