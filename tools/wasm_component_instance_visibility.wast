;; A child has a named type in its root and uses it in a nested interface.
;; The parent can expose both together, in declaration order.
(component definition
  (component $child
    (core module $m (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (type $record (record (field "x" u32)))
    (export $named "record" (type $record))
    (func $f (result $named) (canon lift (core func $i "f")))
    (instance $api (export "f" (func $f)))
    (export "api" (instance $api)))
  (instance $child-instance (instantiate $child))
  (instance $combined
    (export "record" (type $child-instance "record"))
    (export "api" (instance $child-instance "api")))
  (export "combined" (instance $combined)))

(assert_invalid
  (component
    (component $child
      (core module $m (func (export "f") (result i32) unreachable))
      (core instance $i (instantiate $m))
      (type $record (record (field "x" u32)))
      (export $named "record" (type $record))
      (func $f (result $named) (canon lift (core func $i "f")))
      (instance $api (export "f" (func $f)))
      (export "api" (instance $api)))
    (instance $child-instance (instantiate $child))
    (instance $combined
      (export "api" (instance $child-instance "api"))
      (export "record" (type $child-instance "record")))
    (export "combined" (instance $combined)))
  "instance not valid to be used as export")

;; Ascription supplies the visible names for structurally equal value types.
(component definition
  (type $record (record (field "x" u32)))
  (type $private-record (record (field "x" u32)))
  (type $wrapper (record (field "r" $private-record)))
  (instance $bag
    (export "item" (type $record))
    (export "wrap" (type $wrapper)))
  (type $contract (instance
    (type $r (record (field "x" u32)))
    (export "item" (type $named (eq $r)))
    (type $w (record (field "r" $named)))
    (export "wrap" (type (eq $w)))))
  (export "bag" (instance $bag) (instance (type $contract))))

;; Instantiation substitutes the parent's imported name in a child function.
(component definition
  (type $record (record (field "x" u32)))
  (import "record" (type $named (eq $record)))
  (component $child
    (type $record (record (field "x" u32)))
    (import "record" (type $named (eq $record)))
    (core module $m (func (export "f") (result i32) unreachable))
    (core instance $i (instantiate $m))
    (func (export "f") (result $named) (canon lift (core func $i "f"))))
  (instance $child-instance (instantiate $child (with "record" (type $named))))
  (export "f" (func $child-instance "f")))

;; The function index created by an export has the ascribed visible type.
(component definition
  (core module $m (func (export "f") (result i32) unreachable))
  (core instance $i (instantiate $m))
  (type $record (record (field "x" u32)))
  (func $f (result $record) (canon lift (core func $i "f")))
  (export $named "record" (type $record))
  (export $public "first" (func $f) (func (result $named)))
  (export "second" (func $public)))
