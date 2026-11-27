;; The async function type is independent of the choice of a canonical ABI.
;; An async-typed function can complete synchronously and be lowered with
;; the synchronous ABI by another component.
(component
  (component $provider
    (core module $m (func (export "produce") (result i32) (i32.const 42)))
    (core instance $i (instantiate $m))
    (func (export "produce") async (result u32) (canon lift (core func $i "produce"))))
  (component $consumer
    (import "produce" (func $produce async (result u32)))
    (core func $call (canon lower (func $produce)))
    (func (export "run") (result u32) (canon lift (core func $call))))
  (instance $p (instantiate $provider))
  (instance $c (instantiate $consumer (with "produce" (func $p "produce"))))
  (export "run" (func $c "run")))

(assert_return (invoke "run") (u32.const 42))

(assert_invalid
  (component
    (import "synchronous" (func $f (result u32)))
    (component $consumer (import "f" (func async (result u32))))
    (instance (instantiate $consumer (with "f" (func $f)))))
  "component instantiation argument type mismatch")

(assert_invalid
  (component
    (import "asynchronous" (func $f async (result u32)))
    (component $consumer (import "f" (func (result u32))))
    (instance (instantiate $consumer (with "f" (func $f)))))
  "component instantiation argument type mismatch")
