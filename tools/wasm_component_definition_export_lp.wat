(component
  (component $work
    (core module $code (func (export "run") (result i32) (i32.const 42)))
    (core instance $core (instantiate $code))
    (func (export "run") (result u32) (canon lift (core func $core "run"))))
  (export $definition "definition" (component $work)
    (component (export "run" (func (result u32)))))
  (instance $worker (instantiate $definition))
  (func (export "run") (alias export $worker "run")))
