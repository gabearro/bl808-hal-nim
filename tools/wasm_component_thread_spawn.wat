(component
  (core type $entry (func (param i32)))
  (core func $spawn (canon thread.spawn-ref $entry))
  (core func $return (canon task.return (result u32)))
  (core module $m
    (type $entry (func (param i32)))
    (import "" "s" (func $spawn (param (ref null $entry) i32) (result i32)))
    (import "" "r" (func $return (param i32)))
    (func $worker (type $entry) (call $return (local.get 0)))
    (elem declare func $worker)
    (func (export "run")
      (if (i32.le_s (call $spawn (ref.func $worker) (i32.const 42)) (i32.const 0))
        (then unreachable))))
  (core instance $m (instantiate $m (with "" (instance
    (export "s" (func $spawn)) (export "r" (func $return))))))
  (func (export "run") async (result u32) (canon lift (core func $m "run") async)))
