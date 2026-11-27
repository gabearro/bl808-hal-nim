(module
  (memory 1 1 shared)
  (func (export "wait32") (param i32 i32 i64) (result i32)
    (memory.atomic.wait32 (local.get 0) (local.get 1) (local.get 2)))
  (func (export "wait64") (param i32 i64 i64) (result i32)
    (memory.atomic.wait64 (local.get 0) (local.get 1) (local.get 2)))
  (func (export "notify") (param i32 i32) (result i32)
    (memory.atomic.notify (local.get 0) (local.get 1)))
  (func (export "store") (param i32 i64)
    (i64.atomic.store (local.get 0) (local.get 1)))
  (func (export "timer") (result i32)
    (memory.atomic.wait32 (i32.const 0) (i32.const 0) (i64.const 5000))))
(assert_return (invoke "wait32" (i32.const 0) (i32.const 1) (i64.const 0)) (i32.const 1))
(assert_return (invoke "wait32" (i32.const 0) (i32.const 0) (i64.const 0)) (i32.const 2))
(assert_return (invoke "wait64" (i32.const 0) (i64.const -1) (i64.const 0)) (i32.const 1))
(assert_return (invoke "notify" (i32.const 0) (i32.const -1)) (i32.const 0))
(assert_trap (invoke "wait64" (i32.const 4) (i64.const 0) (i64.const 0)) "unaligned atomic memory access")
(assert_trap (invoke "wait32" (i32.const 65536) (i32.const 0) (i64.const 0)) "out of bounds memory access")
(assert_trap (invoke "notify" (i32.const 1) (i32.const 0)) "unaligned atomic memory access")

(module
  (memory 1)
  (func (export "wait") (result i32)
    (memory.atomic.wait32 (i32.const 0) (i32.const 1) (i64.const 0)))
  (func (export "notify") (result i32)
    (memory.atomic.notify (i32.const 0) (i32.const -1))))
(assert_trap (invoke "wait") "atomic wait on unshared memory")
(assert_return (invoke "notify") (i32.const 0))

;; The native probe runs these exports on two arenas in the same store.
(module
  (memory 1 1 shared)
  (func (export "wait") (result i32)
    (memory.atomic.wait64 (i32.const 0) (i64.const 0) (i64.const -1)))
  (func (export "notify") (result i32)
    (memory.atomic.notify (i32.const 0) (i32.const 1))))
(assert_return (invoke "notify") (i32.const 0))

(assert_invalid
  (module (memory 1 1 shared) (func (result i32)
    (memory.atomic.wait64 align=4 (i32.const 0) (i64.const 0) (i64.const 0))))
  "atomic alignment must be natural")
(assert_invalid
  (module (memory 1 1 shared) (func (result i32)
    (memory.atomic.wait32 (i32.const 0) (i64.const 0) (i64.const 0))))
  "type mismatch")
(assert_invalid
  (module (func (result i32) (memory.atomic.notify (i32.const 0) (i32.const 1))))
  "unknown memory")
