(module
  (type $unary (shared (func (param i32) (result i32))))
  (type $binary (shared (func (param i32 i32) (result i32))))
  (func $double (export "double") (type $unary)
    (i32.mul (local.get 0) (i32.const 2)))
  (func $count (export "count") (type $binary)
    (if (result i32) (i32.eqz (local.get 0))
      (then (local.get 1))
      (else
        (return_call_ref $binary (i32.sub (local.get 0) (i32.const 1))
          (i32.add (local.get 1) (i32.const 1)) (ref.func $count)))))
  (func (export "call") (type $unary)
    (local (ref null (shared func)))
    (local.set 1 (ref.null (shared nofunc)))
    (drop (local.get 1))
    (call_ref $unary (local.get 0) (ref.func $double)))
  (func (export "tail") (type $unary)
    (return_call_ref $binary (local.get 0) (i32.const 0) (ref.func $count))))
(assert_return (invoke "call" (i32.const 21)) (i32.const 42))
(assert_return (invoke "tail" (i32.const 1024)) (i32.const 1024))

(module
  (type $entry (shared (func (result i32))))
  (func (export "null") (type $entry)
    (call_ref $entry (ref.null (shared nofunc)))))
(assert_trap (invoke "null") "null function reference")

(module
  (type $value (shared (func (result i32))))
  (type $identity (shared (func (param (ref $value)) (result (ref $value)))))
  (func (export "identity") (type $identity) (local.get 0)))
(register "provider")
(module
  (type $unused (func (param f64)))
  (type $renumbered (shared (func (result i32))))
  (type $identity (shared (func (param (ref $renumbered)) (result (ref $renumbered)))))
  (type $plain-result (func (result i32)))
  (import "provider" "identity" (func $identity (type $identity)))
  (func $forty-two (export "value") (type $renumbered) (i32.const 42))
  (func (export "plain-value") (type $plain-result) (i32.const 42))
  (func (export "linked") (type $renumbered)
    ref.func $forty-two
    block (type $identity)
      call $identity
    end
    call_ref $renumbered))
(assert_return (invoke "linked") (i32.const 42))

(assert_unlinkable
  (module
    (type $value (shared (func (result i32))))
    (import "provider" "identity" (func (param (ref $value)) (result (ref $value)))))
  "incompatible import type")

(assert_invalid
  (module (type (shared (func (param funcref)))))
  "unshared")

(assert_invalid
  (module (type (shared (func (result funcref)))))
  "unshared")

(assert_invalid
  (module
    (type $plain (sub (func)))
    (type (sub $plain (shared (func)))))
  "subtype")

(assert_invalid
  (module
    (type $shared (shared (func)))
    (type $unshared (func))
    (func $plain (type $unshared))
    (func (type $shared) (call $plain)))
  "unshared")

(assert_invalid
  (module
    (type $shared (shared (func)))
    (type $plain (func))
    (func (type $shared) (block (type $plain))))
  "unshared")

(assert_invalid
  (module
    (type $shared (shared (func (result i32))))
    (global $g i32 (i32.const 1))
    (func (type $shared) (global.get $g)))
  "unshared")

(assert_invalid
  (module
    (type $shared (shared (func (result i32))))
    (table $t 1 funcref)
    (func (type $shared) (table.size $t)))
  "unshared")

(assert_invalid
  (module
    (type $shared (shared (func)))
    (func $f (export "f") (type $shared))
    (func (local $f funcref) (local.set $f (ref.func $f))))
  "type mismatch")

(assert_invalid
  (module (global funcref (ref.null (shared func))))
  "type mismatch")
