(module
  (type $unary (func (param i32) (result i32)))
  (type $binary (func (param i32 i32) (result i32)))
  (func $double (type $unary) (i32.add (local.get 0) (local.get 0)))
  (func $count (type $binary)
    (if (result i32) (i32.eqz (local.get 0))
      (then (local.get 1))
      (else
        (return_call_ref $binary (i32.sub (local.get 0) (i32.const 1))
          (i32.add (local.get 1) (i32.const 1)) (ref.func $count)))))
  (func $retain (param (ref $unary)) (result (ref $unary)) (local.get 0))
  (table $entries 1 1 (ref $unary) (ref.func $double))
  (elem declare func $count)
  (func (export "call") (param i32) (result i32)
    (local $f (ref null $unary))
    (local $empty nullfuncref)
    (local.set $f (local.get $empty))
    (local.set $f (table.get $entries (i32.const 0)))
    (call_ref $unary (local.get 0) (call $retain (ref.as_non_null (local.get $f)))))
  (func (export "tail") (param i32) (result i32)
    (return_call_ref $binary (local.get 0) (i32.const 0) (ref.func $count))))
(assert_return (invoke "call" (i32.const 21)) (i32.const 42))
(assert_return (invoke "tail" (i32.const 1024)) (i32.const 1024))

(module
  (type $unary (func (param i32) (result i32)))
  (global $empty funcref (ref.null nofunc))
  (func (export "null") (result i32)
    (call_ref $unary (i32.const 1) (ref.null $unary)))
  (func (export "null-local") (result i32)
    (local $f (ref null $unary))
    (call_ref $unary (i32.const 1) (local.get $f)))
  (func (export "null-bottom") (result i32)
    (call_ref $unary (i32.const 1) (ref.null nofunc)))
  (func (export "null-extern") (result i32)
    (local $r externref)
    (ref.is_null (local.get $r)))
  (func (export "nonnull-trap")
    (drop (ref.as_non_null (global.get $empty)))))
(assert_trap (invoke "null") "null function reference")
(assert_trap (invoke "null-local") "null function reference")
(assert_trap (invoke "null-bottom") "null function reference")
(assert_return (invoke "null-extern") (i32.const 1))
(assert_trap (invoke "nonnull-trap") "null reference")

(module
  (rec
    (type $one (func (param (ref null $two)) (result i32)))
    (type $two (func (param (ref null $one)) (result i32))))
  (func $value (type $two) (i32.const 42))
  (elem declare func $value)
  (func (export "recursive-group") (result i32)
    (call_ref $two (ref.null $one) (ref.func $value))))
(assert_return (invoke "recursive-group") (i32.const 42))

(module
  (type $target (func (result i32)))
  (type $base (sub (func (param (ref $target)) (result (ref null $target)))))
  (type $derived (sub $base (func (param (ref null $target)) (result (ref $target)))))
  (func $value (type $target) (i32.const 42))
  (func $use (type $derived) (ref.func $value))
  (elem declare func $value $use)
  (func (export "variance") (result i32)
    (call_ref $target (call_ref $base (ref.func $value) (ref.func $use)))))
(assert_return (invoke "variance") (i32.const 42))

(module
  (type $value (func (result i32)))
  (type $identity (func (param (ref $value)) (result (ref $value))))
  (func (export "identity") (type $identity) (local.get 0)))
(register "provider")
(module
  (type $unused (func (param f64)))
  (type $renumbered (func (result i32)))
  (type $identity (func (param (ref $renumbered)) (result (ref $renumbered))))
  (import "provider" "identity" (func $identity (type $identity)))
  (func $forty-two (type $renumbered) (i32.const 42))
  (elem declare func $forty-two)
  (func (export "linked") (result i32)
    ref.func $forty-two
    block (type $identity)
      call $identity
    end
    call_ref $renumbered))
(assert_return (invoke "linked") (i32.const 42))

(assert_unlinkable
  (module
    (type $wrong (func (result i64)))
    (import "provider" "identity" (func (param (ref $wrong)) (result (ref $wrong)))))
  "incompatible import type")

(assert_invalid
  (module
    (type $unary (func (param i32) (result i32)))
    (func $wrong (param i64) (result i32) (i32.const 0))
    (elem declare func $wrong)
    (func (result i32) (call_ref $unary (i32.const 1) (ref.func $wrong))))
  "type mismatch")

(assert_invalid
  (module
    (type $unary (func (param i32) (result i32)))
    (func (param funcref) (result i32)
      (call_ref $unary (i32.const 1) (local.get 0))))
  "type mismatch")

(assert_invalid
  (module
    (type $a (func (param i32)))
    (type $b (func (param i64)))
    (func (local $r (ref null $a))
      (local.set $r (ref.null $b))))
  "type mismatch")

(assert_invalid
  (module
    (type $a (func (param i32)))
    (func (local $r (ref null $a))
      (local.set $r (i32.add (i32.const 1) (i32.const 2)))))
  "type mismatch")

(assert_invalid
  (module
    (type $returns-i64 (func (result i64)))
    (func $f (type $returns-i64) (i64.const 1))
    (elem declare func $f)
    (func (result i32) (return_call_ref $returns-i64 (ref.func $f))))
  "type mismatch")

(assert_invalid
  (module (func (drop (ref.null 9))))
  "unknown type")

(assert_invalid
  (module
    (func $f)
    (elem declare func $f)
    (func (local $null nullfuncref)
      (local.set $null (ref.func $f))))
  "type mismatch")

(assert_invalid
  (module
    (type $target (func))
    (func $nonnull (param (ref $target)))
    (func (call $nonnull (ref.null $target))))
  "type mismatch")

(assert_invalid
  (module
    (type $target (func))
    (func (result (ref $target)) (ref.null $target)))
  "type mismatch")

(assert_invalid
  (module
    (type $target (func))
    (type $base (sub (func (param (ref null $target)))))
    (type $invalid (sub $base (func (param (ref $target))))))
  "subtype")

;; Abstract heap types have one-byte encodings. This is an invalid signed
;; LEB encoding of func (-16) in ref.null.
(assert_malformed
  (module binary
    "\00asm\01\00\00\00\01\04\01\60\00\00\03\02\01\00"
    "\0a\08\01\06\00\d0\f0\7f\1a\0b")
  "invalid heap type")

(module
  (func $value (result i32) (i32.const 42))
  (global (export "reference") funcref (ref.func $value)))
(register "table-global")
(module
  (type $result (func (result i32)))
  (import "table-global" "reference" (global $reference funcref))
  (table $table 2 funcref (global.get $reference))
  (func $override (type $result) (i32.const 9))
  (elem (table $table) (i32.const 0) (ref $result) (ref.func $override))
  (func (export "global-initializer") (param i32) (result i32)
    (call_indirect $table (type $result) (local.get 0)))
  (func (export "grow-overflow") (result i32)
    (table.grow $table (table.get $table (i32.const 0)) (i32.const -1))))
(assert_return (invoke "global-initializer" (i32.const 0)) (i32.const 9))
(assert_return (invoke "global-initializer" (i32.const 1)) (i32.const 42))
(assert_return (invoke "grow-overflow") (i32.const -1))
(assert_return (invoke "global-initializer" (i32.const 1)) (i32.const 42))

(assert_invalid
  (module (type $entry (func)) (table 0 (ref $entry)))
  "type mismatch")
(assert_invalid
  (module (type $entry (func)) (table 1 (ref $entry) (ref.null $entry)))
  "type mismatch")
(assert_invalid
  (module
    (global $reference funcref (ref.null func))
    (table 1 funcref (global.get $reference)))
  "global")
(assert_invalid
  (module
    (type $entry (func))
    (func $initializer (type $entry))
    (table $table 1 (ref $entry) (ref.func $initializer))
    (elem (table $table) (i32.const 0) (ref null $entry) (ref.func $initializer)))
  "type mismatch")

(assert_malformed
  (module binary "\00asm\01\00\00\00\04\09\01\40\01\70\00\01\d0\70\0b")
  "invalid table initializer")

(module
  (type $entry (func (result i32)))
  (func $value (type $entry) (i32.const 42))
  (global $constant (export "constant") (ref $entry) (ref.func $value))
  (global $current (export "current") (mut (ref $entry)) (global.get $constant))
  (func (export "typed-globals") (result i32)
    (global.set $current (global.get $constant))
    (call_ref $entry (global.get $current))))
(assert_return (invoke "typed-globals") (i32.const 42))
(register "typed-globals")

(module
  (type $another (func (param i64)))
  (type $entry (func (result i32)))
  (import "typed-globals" "constant" (global $seed (ref null $entry)))
  (import "typed-globals" "current" (global $current (mut (ref $entry))))
  (global $saved (ref null $entry) (global.get $seed))
  (func (export "read-global") (result i32)
    (i32.add (call_ref $entry (global.get $saved))
      (call_ref $entry (global.get $current)))))
(assert_return (invoke "read-global") (i32.const 84))

(assert_unlinkable
  (module
    (type $entry (func (result i32)))
    (import "typed-globals" "current" (global (mut (ref null $entry)))))
  "incompatible import type")

(assert_invalid
  (module
    (type $entry (func))
    (global (ref $entry) (ref.null $entry)))
  "type mismatch")

(assert_invalid
  (module
    (type $entry (func))
    (func $noop (type $entry))
    (global $current (mut (ref $entry)) (ref.func $noop))
    (func (global.set $current (ref.null $entry))))
  "type mismatch")
