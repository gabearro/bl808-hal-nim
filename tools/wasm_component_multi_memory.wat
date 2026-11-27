(component
  (core module $module
    (memory $scratch 1 1)
    (memory $result-memory (export "result-memory") 1 1)
    (data (memory $result-memory) (i32.const 16) "Ox64")
    (func (export "run") (result i32)
      (i32.store $scratch (i32.const 16) (i32.const 0))
      (i32.store $result-memory (i32.const 4) (i32.const 16))
      (i32.store $result-memory (i32.const 8) (i32.const 4))
      (i32.const 4)))
  (core instance $instance (instantiate $module))
  (func (export "run") (result string)
    (canon lift (core func $instance "run")
      (memory (core memory $instance "result-memory")))))
