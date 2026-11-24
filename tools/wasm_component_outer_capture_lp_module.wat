(component
  (import "engine" (core module $engine (export "run" (func (result i32)))))
  (component $worker
    (alias outer 1 $engine (core module $engine))
    (core instance $code (instantiate $engine))
    (func (export "run") (result u32) (canon lift (core func $code "run"))))
  (instance $work (instantiate $worker))
  (func (export "run") (alias export $work "run")))
