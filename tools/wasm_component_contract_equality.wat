(component
  (type $Rich (component
    (export "run" (func (result u32)))
    (export "extra" (func (result u32)))))
  (type $Thin (component (export "run" (func (result u32)))))
  (export $public "factory-shape" (type $Rich) (type (eq $Thin)))
  (type $Envelope (component
    (alias outer 1 $Thin (type $Contract))
    (export "shape" (type (eq $Contract)))
    (export "box" (instance
      (alias outer 1 $Contract (type $Nested))
      (export "factory-shape" (type (eq $Nested)))))))
  (component $schemas
    (alias outer 1 $Rich (type $Contract))
    (export "shape" (type $Contract))
    (instance $box (export "factory-shape" (type $Contract)))
    (export "box" (instance $box)))
  (component $relay
    (alias outer 1 $Envelope (type $Envelope))
    (import "schemas" (component $schemas (type $Envelope)))
    (instance $relay (instantiate $schemas))
    (alias export $relay "shape" (type $Shape))
    (export "shape" (type $Shape))
    (export "box" (instance $relay "box")))
  (instance $relayed (instantiate $relay (with "schemas" (component $schemas))))
  (alias export $relayed "box" (instance $box))

  (component $provider
    (core module $code (func (export "answer") (result i32) (i32.const 42)))
    (core instance $code (instantiate $code))
    (func (export "run") (result u32) (canon lift (core func $code "answer")))
    (func (export "extra") (result u32) (canon lift (core func $code "answer"))))

  (component $consumer
    (type $Required (component (export "run" (func (result u32)))))
    (import "shape" (type $Shape (eq $Required)))
    (import "box" (instance $box
      (alias outer 1 $Shape (type $Schema))
      (export "factory-shape" (type (eq $Schema)))))
    (alias export $box "factory-shape" (type $Factory))
    (import "factory" (component $factory (type $Factory)))
    (instance $product (instantiate $factory))
    (func (export "run") (alias export $product "run")))
  (instance $run (instantiate $consumer
    (with "shape" (type $Rich))
    (with "box" (instance $box))
    (with "factory" (component $provider))))
  (func (export "run") (alias export $run "run")))
