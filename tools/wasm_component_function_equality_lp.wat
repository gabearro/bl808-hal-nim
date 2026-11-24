(component
  (type $Read (func (result u32)))
  (component $worker
    (type $Read (func (result u32)))
    (import "signature" (type $bound (eq $Read)))
    (core module $code (func (export "run") (result i32) (i32.const 42)))
    (core instance $code (instantiate $code))
    (func (export "run") (type $bound) (canon lift (core func $code "run"))))
  (export $published "typedef" (type $Read) (type (eq $Read)))
  (instance $box (export "signature" (type $published)))
  (alias export $box "signature" (type $forward))
  (instance $worker (instantiate $worker (with "signature" (type $forward))))
  (func (export "run") (alias export $worker "run")))
