(component
  (type $r (resource (rep i32)))
  (export $named "r" (type $r))
  (core func $new (canon resource.new $r))
  (func (export "make") (param "value" u32) (result (own $named))
    (canon lift (core func $new)))
  (component $child
    (import "r" (type $incoming (sub resource)))
    (core func $drop (canon resource.drop $incoming))
    (func $consume (param "value" (own $incoming)) (canon lift (core func $drop)))
    (instance $api (export "consume" (func $consume)))
    (export "api" (instance $api)))
  (instance $child-instance (instantiate $child (with "r" (type $named))))
  (export "api" (instance $child-instance "api")))
