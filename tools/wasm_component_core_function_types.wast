;; The base is encoded independently in the component and in both core
;; modules. The provider exports a descendant, which can satisfy the typed
;; module export as well as the other module's import.
(component
  (core type $base (sub (func (param i32) (result i32))))
  (core type $contract (module
    (alias outer 1 $base (type $expected))
    (export "f" (func (type $expected)))))
  (core module $provider
    (type $base (sub (func (param i32) (result i32))))
    (type $middle (sub $base (func (param i32) (result i32))))
    (type $leaf (sub final $middle (func (param i32) (result i32))))
    (func (export "f") (type $leaf)
      local.get 0
      i32.const 1
      i32.add))
  (export "provider" (core module $provider) (core module (type $contract)))
  (core instance $p (instantiate $provider))
  (core module $consumer
    (type $base (sub (func (param i32) (result i32))))
    (import "env" "f" (func $f (type $base)))
    (func (export "run") (result i32)
      i32.const 41
      call $f))
  (core instance $c (instantiate $consumer (with "env" (instance $p))))
  (func (export "run") (result u32) (canon lift (core func $c "run"))))
(assert_return (invoke "run") (u32.const 42))

;; The types in an explicit group occupy distinct type indices. The leaf
;; inherits its base and the same-shape sibling has its own type identity.
(component
  (core module $m
    (rec
      (type $base (sub (func (result i32))))
      (type $leaf (sub final $base (func (result i32))))
      (type $sibling (func (result i32))))
    (func $f (type $leaf) i32.const 42)
    (table 1 funcref)
    (elem (i32.const 0) func $f)
    (func (export "run") (result i32)
      i32.const 0
      call_indirect (type $base))
    (func (export "tail") (result i32)
      i32.const 0
      return_call_indirect (type $base))
    (func (export "bad") (result i32)
      i32.const 0
      call_indirect (type $sibling)))
  (core instance $i (instantiate $m))
  (func (export "run") (result u32) (canon lift (core func $i "run")))
  (func (export "tail") (result u32) (canon lift (core func $i "tail")))
  (func (export "bad") (result u32) (canon lift (core func $i "bad"))))
(assert_return (invoke "run") (u32.const 42))
(assert_return (invoke "tail") (u32.const 42))
(assert_trap (invoke "bad") "indirect call type mismatch")

;; A final singleton without a supertype canonicalizes to the ABI's
;; implicit function type even when a tool encodes an explicit group.
(component
  (core module $m
    (rec (type $f (sub final (func (result i32)))))
    (func (export "f") (type $f) i32.const 42))
  (core instance $i (instantiate $m))
  (func (export "run") (result u32) (canon lift (core func $i "f"))))
(assert_return (invoke "run") (u32.const 42))

(assert_invalid
  (component
    (core type $contract (module
      (type $base (sub (func (result i32))))
      (type $leaf (sub final $base (func (result i32))))
      (export "f" (func (type $leaf)))))
    (core module $provider
      (type $base (sub (func (result i32))))
      (func (export "f") (type $base) i32.const 42))
    (export "provider" (core module $provider) (core module (type $contract))))
  "core module export type mismatch")

(assert_invalid
  (component
    (core module $m
      (type $base (sub (func (result i32))))
      (func (export "f") (type $base) i32.const 42))
    (core instance $i (instantiate $m))
    (func (export "run") (result u32) (canon lift (core func $i "f"))))
  "canonical function type mismatch")

(assert_invalid
  (component
    (core module
      (type $base (func (result i32)))
      (type (sub final $base (func (result i32))))))
  "core function supertype is final")

(assert_invalid
  (component
    (core module
      (type $base (sub (func (result i32))))
      (type (sub final $base (func (result i64))))))
  "core function supertype signature mismatch")

;; A module can be ascribed a tighter import requirement. Independently
;; encoded copies of the group match even at different absolute indices.
(component
  (core type $contract (module
    (type (func))
    (rec
      (type $base (sub (func (result i32))))
      (type $leaf (sub final $base (func (result i32)))))
    (import "env" "f" (func (type $leaf)))
    (export "run" (func (result i32)))))
  (core module $consumer
    (rec
      (type $base (sub (func (result i32))))
      (type $leaf (sub final $base (func (result i32)))))
    (import "env" "f" (func $f (type $base)))
    (func (export "run") (result i32) call $f))
  (export "consumer" (core module $consumer) (core module (type $contract)))
  (core module $provider
    (rec
      (type $base (sub (func (result i32))))
      (type $leaf (sub final $base (func (result i32)))))
    (func (export "f") (type $leaf) i32.const 42))
  (core instance $p (instantiate $provider))
  (core instance $c (instantiate $consumer (with "env" (instance $p))))
  (func (export "run") (result u32) (canon lift (core func $c "run"))))
(assert_return (invoke "run") (u32.const 42))

;; An import of a member of a recursive group requires that entire group's
;; canonical identity, including members unused by the importing function.
(assert_invalid
  (component
    (core module $provider
      (rec (type $f (func (result i32))) (type (func (param f32))))
      (func (export "f") (type $f) i32.const 42))
    (core module $consumer
      (rec (type $f (func (result i32))) (type (func (param f64))))
      (import "env" "f" (func (type $f))))
    (core instance $p (instantiate $provider))
    (core instance (instantiate $consumer (with "env" (instance $p)))))
  "core import type mismatch")
