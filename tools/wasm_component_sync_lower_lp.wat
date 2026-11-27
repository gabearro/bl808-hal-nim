(component
  (core func $yield (canon thread.yield))
  (core func $return (canon task.return (result u32)))
  (core module $producer
    (import "" "y" (func $yield (result i32)))
    (import "" "r" (func $return (param i32)))
    (func (export "value") (param $value i32)
      (if (call $yield) (then unreachable))
      (call $return (i32.add (local.get $value) (i32.const 1)))))
  (core instance $producer (instantiate $producer (with "" (instance
    (export "y" (func $yield)) (export "r" (func $return))))))
  (func $value async (param "input" u32) (result u32)
    (canon lift (core func $producer "value") async))
  (core func $value (canon lower (func $value)))
  (func (export "run") async (param "input" u32) (result u32)
    (canon lift (core func $value))))
