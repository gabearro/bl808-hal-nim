(component
  (import "observe" (func $observe (param "value" u32)))
  (core func $observe (canon lower (func $observe)))
  (type $ticket (resource (rep i32) (dtor (core func $observe))))
  (export $public-ticket "ticket" (type $ticket))
  (core func $new (canon resource.new $ticket))
  (func (export "make") (param "value" u32) (result (own $public-ticket))
    (canon lift (core func $new)))
  (core module $module
    (import "" "new" (func $new (param i32) (result i32)))
    (func (export "make") (param i32) (result i32) (call $new (local.get 0)))
    (func (export "answer") (result i32) i32.const 42))
  (core instance $instance (instantiate $module
    (with "" (instance (export "new" (func $new))))))
  (func (export "make-linked") (param "value" u32) (result (own $public-ticket))
    (canon lift (core func $instance "make")))
  (func (export "trap") (result u32)
    (canon lift (core func $instance "answer") (post-return (core func $observe)))))
