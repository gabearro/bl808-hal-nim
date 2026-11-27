(module
  (type $entry (shared (func (param i32) (result i32))))
  (global $factor (shared mut i32) (i32.const 0))
  (func $double (type $entry) (i32.mul (local.get 0) (global.get $factor)))
  (table $table (export "table") shared 1 2 (ref $entry) (ref.func $double))
  (elem $late (ref $entry) (ref.func $double))
  (elem $declaration declare (ref $entry) (ref.func $double))
  (func (export "run") (type $entry)
    (global.set $factor (i32.const 2))
    (drop (table.grow $table (table.get $table (i32.const 0)) (i32.const 1)))
    (table.copy $table $table (i32.const 1) (i32.const 0) (i32.const 1))
    (table.fill $table (i32.const 0) (table.get $table (i32.const 1)) (i32.const 1))
    (table.set $table (i32.const 0) (table.get $table (i32.const 1)))
    (i32.add (i32.sub (table.size $table) (i32.const 2))
      (call_ref $entry (local.get 0) (table.get $table (i32.const 0)))))
  (func (export "initialize") (result i32)
    (table.init $table $late (i32.const 0) (i32.const 0) (i32.const 1))
    (elem.drop $late)
    (call_ref $entry (i32.const 21) (table.get $table (i32.const 0))))
  (func (export "dropped-trap") (result i32)
    (table.init $table $declaration (i32.const 0) (i32.const 0) (i32.const 1))
    (i32.const 0))
  (func (export "dropped-empty-trap") (result i32)
    (table.init $table $declaration (i32.const 0) (i32.const 1) (i32.const 0))
    (i32.const 0)))
(assert_return (invoke "run" (i32.const 21)) (i32.const 42))
(assert_return (invoke "initialize") (i32.const 42))
(assert_trap (invoke "dropped-trap") "out of bounds table access")
(assert_trap (invoke "dropped-empty-trap") "out of bounds table access")
(register "table-provider")

(module
  (type $different-index (func))
  (type $entry (shared (func (param i32) (result i32))))
  (import "table-provider" "table" (table $table shared 1 2 (ref $entry)))
  (func (export "linked") (type $entry)
    (call_ref $entry (local.get 0) (table.get $table (i32.const 1)))))
(assert_return (invoke "linked" (i32.const 21)) (i32.const 42))

(assert_unlinkable
  (module
    (type $entry (shared (func (param i32) (result i32))))
    (import "table-provider" "table" (table 1 2 (ref $entry))))
  "incompatible import type")

(assert_unlinkable
  (module
    (type $entry (shared (func (result i32))))
    (import "table-provider" "table" (table shared 1 2 (ref $entry))))
  "incompatible import type")

(assert_unlinkable
  (module
    (type $entry (shared (func (param i32) (result i32))))
    (import "table-provider" "table" (table shared 1 2 (ref null $entry))))
  "incompatible import type")

(assert_invalid (module (table shared 1 2 funcref)) "shared")

(assert_invalid
  (module
    (type $shared (shared (func (result i32))))
    (table $table 1 2 (ref null (shared func)))
    (func (type $shared) (table.size $table)))
  "unshared")

(assert_invalid
  (module
    (table $source 1 funcref)
    (table $target shared 1 (ref null (shared func)))
    (func (table.copy $target $source (i32.const 0) (i32.const 0) (i32.const 1))))
  "type mismatch")

(assert_invalid
  (module
    (type $entry (shared (func (result i32))))
    (table $table shared 1 (ref null $entry))
    (func (result i32) (call_indirect $table (type $entry) (i32.const 0))))
  "indirect calls")

(module
  (type $entry (shared (func (result i32))))
  (global $value (export "value") (shared mut i32) (i32.const 7))
  (func $answer (type $entry) (global.get $value))
  (global $seed (shared (ref $entry)) (ref.func $answer))
  (global (export "function") (shared (ref $entry)) (global.get $seed))
  (func (export "read") (type $entry) (call_ref $entry (global.get $seed))))
(assert_return (invoke "read") (i32.const 7))
(register "shared-globals")

(module
  (type $unused (func (param i64)))
  (type $entry (shared (func (result i32))))
  (import "shared-globals" "value" (global $value (shared mut i32)))
  (import "shared-globals" "function" (global $answer (shared (ref null $entry))))
  (func (export "write-provider") (type $entry)
    (global.set $value (i32.const 42))
    (call_ref $entry (global.get $answer))))
(assert_return (invoke "write-provider") (i32.const 42))

(assert_unlinkable
  (module (import "shared-globals" "value" (global (mut i32))))
  "incompatible import type")

(assert_invalid (module (global (shared funcref) (ref.null func))) "shared")

(assert_invalid
  (module (func $private) (global (ref null (shared func)) (ref.func $private)))
  "type mismatch")

(assert_invalid
  (module
    (type $entry (shared (func)))
    (global $value (mut i32) (i32.const 0))
    (func (type $entry) (global.set $value (i32.const 1))))
  "unshared")

(assert_malformed
  (module binary "\00asm\01\00\00\00\06\06\01\7f\04\41\00\0b")
  "malformed global flags")
