(component
  (component $provider
    (core module $engine
      (func (export "run") (result i32) (i32.const 42))
      (func (export "decoy") (result i32) (i32.const -1)))
    (instance $packed
      (export "decoy" (core module $engine))
      (export "engine" (core module $engine)))
    (export "port" (instance $packed) (instance
      (core type $engine-type (module (export "run" (func (result i32)))))
      (export "engine" (core module (type $engine-type))))))
  (instance $child (instantiate $provider))
  (alias export $child "port" (instance $view))
  (alias export $view "engine" (core module $selected))
  (core instance $selected (instantiate $selected))
  (func (export "run") (result u32) (canon lift (core func $selected "run"))))
