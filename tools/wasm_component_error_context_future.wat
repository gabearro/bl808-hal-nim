(component
  (type $future (future error-context))
  (core module $support (memory (export "mem") 1))
  (core instance $support (instantiate $support))
  (core func $read (canon future.read $future (memory (core memory $support "mem"))))
  (core module $app
    (import "" "mem" (memory 1))
    (import "" "read" (func $read (param i32 i32) (result i32)))
    (func (export "read") (param i32) (result i32)
      (if (call $read (local.get 0) (i32.const 0)) (then unreachable))
      (i32.load (i32.const 0))))
  (core instance $app (instantiate $app (with "" (instance
    (export "mem" (memory $support "mem")) (export "read" (func $read))))))
  (func (export "read") (param "incoming" $future) (result error-context)
    (canon lift (core func $app "read"))))
