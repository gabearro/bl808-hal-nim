;; The first module fits the 16 KiB LP execution gate and uses i64 wraparound.
(module
  (type $entry (shared (func (result i32))))
  (global $value (shared mut i64) (i64.const -1))
  (func (export "atomic") (type $entry)
    (if (result i32)
      (i64.eq (global.atomic.rmw.add seqcst $value (i64.const 43)) (i64.const -1))
      (then (i32.wrap_i64 (global.atomic.get acqrel $value)))
      (else (i32.const 0)))))
(assert_return (invoke "atomic") (i32.const 42))

;; Independent wrappers let the oracle compare old and updated values.
(module
  (global $value (mut i32) (i32.const 0))
  (global $fixed i32 (i32.const 37))
  (func (export "read") (result i32) (global.atomic.get seqcst $value))
  (func (export "constant") (result i32) (global.atomic.get seqcst $fixed))
  (func (export "set") (param i32) (result i32)
    (global.atomic.set acqrel $value (local.get 0)) (global.get $value))
  (func (export "add") (param i32) (result i32)
    (global.atomic.rmw.add seqcst $value (local.get 0)))
  (func (export "sub") (param i32) (result i32)
    (global.atomic.rmw.sub seqcst $value (local.get 0)))
  (func (export "and") (param i32) (result i32)
    (global.atomic.rmw.and seqcst $value (local.get 0)))
  (func (export "or") (param i32) (result i32)
    (global.atomic.rmw.or seqcst $value (local.get 0)))
  (func (export "xor") (param i32) (result i32)
    (global.atomic.rmw.xor seqcst $value (local.get 0)))
  (func (export "exchange") (param i32) (result i32)
    (global.atomic.rmw.xchg seqcst $value (local.get 0)))
  (func (export "compare-exchange") (param i32 i32) (result i32)
    (global.atomic.rmw.cmpxchg seqcst $value (local.get 0) (local.get 1))))
(assert_return (invoke "constant") (i32.const 37))
(assert_return (invoke "set" (i32.const -1)) (i32.const -1))
(assert_return (invoke "add" (i32.const 1)) (i32.const -1))
(assert_return (invoke "read") (i32.const 0))
(assert_return (invoke "sub" (i32.const 1)) (i32.const 0))
(assert_return (invoke "and" (i32.const 3)) (i32.const -1))
(assert_return (invoke "or" (i32.const 8)) (i32.const 3))
(assert_return (invoke "xor" (i32.const 3)) (i32.const 11))
(assert_return (invoke "exchange" (i32.const -2147483648)) (i32.const 8))
(assert_return (invoke "compare-exchange" (i32.const -1) (i32.const 12))
  (i32.const -2147483648))
(assert_return (invoke "read") (i32.const -2147483648))
(assert_return (invoke "compare-exchange" (i32.const -2147483648) (i32.const 42))
  (i32.const -2147483648))
(assert_return (invoke "read") (i32.const 42))

(module
  (global $value (shared mut i64) (i64.const -0x100000001))
  (func (export "wide-cmpxchg") (result i32)
    (drop (global.atomic.rmw.cmpxchg seqcst $value (i64.const -1) (i64.const 0)))
    (i32.and
      (i64.eq (global.atomic.rmw.cmpxchg seqcst $value
        (i64.const -0x100000001) (i64.const 0x10000002a)) (i64.const -0x100000001))
      (i64.eq (global.atomic.get seqcst $value) (i64.const 0x10000002a)))))
(assert_return (invoke "wide-cmpxchg") (i32.const 1))

(assert_invalid
  (module (global $g i32 (i32.const 1))
    (func (global.atomic.set seqcst $g (i32.const 0))))
  "immutable global")
(assert_invalid
  (module (global $g i64 (i64.const 1))
    (func (result i64) (global.atomic.rmw.add seqcst $g (i64.const 1))))
  "immutable global")
(assert_invalid
  (module (global $g (mut f32) (f32.const 0))
    (func (result f32) (global.atomic.get seqcst $g)))
  "invalid atomic type")
(assert_invalid
  (module (global $g (mut funcref) (ref.null func))
    (func (result funcref) (global.atomic.rmw.xchg seqcst $g (ref.null func))))
  "invalid atomic type")
(assert_invalid
  (module (global $g (mut i64) (i64.const 1))
    (func (result i64) (global.atomic.rmw.cmpxchg seqcst $g (i32.const 1) (i64.const 42))))
  "type mismatch")
(assert_invalid
  (module
    (type $shared (shared (func (result i32))))
    (global $g i32 (i32.const 0))
    (func (type $shared) (global.atomic.get seqcst $g)))
  "unshared")
(assert_invalid
  (module (func (result i32) (global.atomic.get seqcst 1)))
  "unknown global")
