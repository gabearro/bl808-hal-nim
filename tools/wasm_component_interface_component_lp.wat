(component
  (component $work
    (core module $code
      (func (export "run") (result i32) (i32.const 42))
      (func (export "extra") (result i32) (i32.const 85)))
    (core instance $code (instantiate $code))
    (func (export "run") (result u32) (canon lift (core func $code "run")))
    (func (export "extra") (result u32) (canon lift (core func $code "extra"))))
  (instance $packed
    (export "hidden" (component $work))
    (export "task" (component $work)))
  (export $visible "package" (instance $packed) (instance
    (export "task" (component (export "run" (func (result u32)))))))
  (alias export $visible "task" (component $selected))
  (instance $result (instantiate $selected))
  (func (export "run") (alias export $result "run")))
