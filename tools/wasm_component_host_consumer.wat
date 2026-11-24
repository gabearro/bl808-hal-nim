(component
  (type $contract (component
    (import "offset" (func (result u32)))
    (import "scale" (func (param "value" u32) (result u32)))
    (export "apply" (func (param "value" u32) (result u32)))))
  (import "factory" (component $factory (type $contract)))
  (import "offset" (func $offset (result u32)))
  (import "scale" (func $scale (param "value" u32) (result u32)))
  (import "started" (func $started))
  (core func $signal (canon lower (func $started)))
  (core module $init
    (import "" "signal" (func $signal))
    (start $signal))
  (core instance (instantiate $init (with "" (instance (export "signal" (func $signal))))))
  (instance $api (instantiate $factory (with "offset" (func $offset)) (with "scale" (func $scale))))
  (func (export "apply") (alias export $api "apply")))
