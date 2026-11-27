(component
  (core module $provider
    (type $base (sub (func (result i32))))
    (type $leaf (sub final $base (func (result i32))))
    (func (export "f") (type $leaf) i32.const 42))
  (core module $consumer
    (type $base (sub (func (result i32))))
    (type $entry (func (result i32)))
    (import "env" "f" (func $f (type $base)))
    (func (export "run") (type $entry) call $f))
  (core instance $p (instantiate $provider))
  (core instance $c (instantiate $consumer (with "env" (instance $p))))
  (func (export "run") (result u32) (canon lift (core func $c "run"))))
