(component
  (type $counter (resource (rep i32)))
  (export $public "counter" (type $counter))
  (alias outer 0 $counter (type $local))
  (type $ownership (own $public))
  (alias outer 0 $ownership (type $owned))
  (core func $new (canon resource.new $local))
  (core module $methods
    (import "" "new" (func $new (param i32) (result i32)))
    (func (export "make") (param i32) (result i32)
      local.get 0
      call $new)
    (func (export "get") (param i32) (result i32)
      local.get 0))
  (core instance $impl (instantiate $methods
    (with "" (instance (export "new" (func $new))))))
  (func (export "[constructor]counter") (param "initial" u32) (result $owned)
    (canon lift (core func $impl "make")))
  (func (export "[method]counter.get") (param "self" (borrow $public)) (result u32)
    (canon lift (core func $impl "get")))
)
