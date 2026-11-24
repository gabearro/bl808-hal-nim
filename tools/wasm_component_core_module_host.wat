(component
  (core type $get-type (func (result i32)))
  (core type $module-type (module
    (alias outer 1 $get-type (type $get-type))
    (export "run" (func (type $get-type)))))
  (import "engine" (core module $engine (type $module-type)))
  (core instance $instance (instantiate $engine))
  (func (export "run") (result u32) (canon lift (core func $instance "run"))))
