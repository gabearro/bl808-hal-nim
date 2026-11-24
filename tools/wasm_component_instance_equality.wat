(component
  (type $Rich (instance
    (export "read" (func (result u32)))
    (export "extra" (func))))
  (type $Thin (instance (export "read" (func (result u32)))))
  (export $type "view" (type $Rich) (type (eq $Thin)))
  (type $Envelope (component
    (alias outer 1 $Thin (type $Type))
    (export "shape" (type (eq $Type)))
    (export "box" (instance
      (alias outer 1 $Type (type $Nested))
      (export "shape" (type (eq $Nested)))))))
  (component $shapes
    (alias outer 1 $Rich (type $Type))
    (export "shape" (type $Type))
    (instance $box (export "shape" (type $Type)))
    (export "box" (instance $box)))
  (component $relay
    (alias outer 1 $Envelope (type $Envelope))
    (import "shapes" (component $shapes (type $Envelope)))
    (instance $relay (instantiate $shapes))
    (alias export $relay "shape" (type $Shape))
    (export "shape" (type $Shape))
    (export "box" (instance $relay "box")))
  (instance $relayed (instantiate $relay (with "shapes" (component $shapes))))
  (alias export $relayed "box" (instance $box))
  (component $provider
    (core module $impl (func (export "answer") (result i32) (i32.const 42)))
    (core instance $impl (instantiate $impl))
    (func (export "read") (result u32) (canon lift (core func $impl "answer"))))
  (instance $provider (instantiate $provider))
  (component $consumer
    (type $Required (instance (export "read" (func (result u32)))))
    (import "shape" (type $Shape (eq $Required)))
    (import "box" (instance $box
      (alias outer 1 $Shape (type $Inner))
      (export "shape" (type (eq $Inner)))))
    (alias export $box "shape" (type $Interface))
    (import "api" (instance $api (type $Interface)))
    (func (export "run") (alias export $api "read")))
  (instance $run (instantiate $consumer
    (with "shape" (type $Rich))
    (with "box" (instance $box))
    (with "api" (instance $provider))))
  (func (export "run") (alias export $run "run")))
