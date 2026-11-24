(component
  (type $first (resource (rep i32)))
  (type $second (resource (rep i32)))
  (export $a "first" (type $first))
  (export $b "second" (type $second))
  (type $FA (func (param "v" (borrow $a)) (result u32)))
  (type $FB (func (param "v" (borrow $b)) (result u32)))
  (component $consumer
    (import "resource" (type $r (sub resource)))
    (type $F (func (param "v" (borrow $r)) (result u32)))
    (import "signature" (type $Use (eq $F))))
  (instance (instantiate $consumer (with "resource" (type $a)) (with "signature" (type $FA)))))
