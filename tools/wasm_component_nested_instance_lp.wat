(component
  (core module $code (func (export "run") (result i32) (i32.const 42)))
  (core instance $code (instantiate $code))
  (type $result (func (result u32)))
  (alias outer 0 $result (type $operation))
  (func $run (type $operation) (canon lift (core func $code "run")))
  (instance $inner (export "extra" (func $run)) (export "run" (func $run)))
  (instance $outer (export "inner" (instance $inner)))
  (export "api" (instance $outer) (instance
    (type $shape (instance
      (alias outer 2 $result (type $method))
      (export "run" (func (type $method)))))
    (alias outer 0 $shape (type $inner-shape))
    (export "inner" (instance (type $inner-shape))))))
