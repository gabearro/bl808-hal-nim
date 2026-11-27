;; The native probe touches two resident chunks on opposite sides of a
;; guest page boundary. Each naturally aligned atomic stays in one chunk.
(module
  (type $entry (shared (func (result i32))))
  (memory 1 2 shared)
  (func (export "atomics") (type $entry)
    (drop (memory.grow (i32.const 1)))
    (i64.atomic.store (i32.const 65528) (i64.const -1))
    (i32.atomic.store (i32.const 65536) (i32.const 0))
    (if (result i32)
      (i64.eq (i64.atomic.rmw.add (i32.const 65528) (i64.const 43)) (i64.const -1))
      (then
        (atomic.fence)
        (i32.add (i32.wrap_i64 (i64.atomic.load (i32.const 65528)))
          (i32.atomic.load (i32.const 65536))))
      (else (i32.const 0)))))
(assert_return (invoke "atomics") (i32.const 42))

;; With one resident frame, the RMW to offset 512 first reads logical
;; zero and parks on the write. The next RMW parks while reading offset 0.
(module
  (memory 1 1 shared)
  (func (export "fault") (result i32)
    (i64.atomic.store (i32.const 0) (i64.const 41))
    (drop (i64.atomic.rmw.add (i32.const 512) (i64.const 77)))
    (drop (i64.atomic.rmw.add (i32.const 0) (i64.const 1)))
    (i32.wrap_i64 (i64.atomic.load (i32.const 0))))
  (func (export "other-word") (result i32)
    (i32.wrap_i64 (i64.atomic.load (i32.const 512)))))
(assert_return (invoke "fault") (i32.const 42))
(assert_return (invoke "other-word") (i32.const 77))

(module
  (memory 1)
  (func (export "subword") (result i32)
    (i64.atomic.store32 (i32.const 4) (i64.const -1))
    (drop (i64.atomic.rmw32.add_u (i32.const 4) (i64.const 1)))
    (drop (i64.atomic.rmw16.sub_u (i32.const 4) (i64.const 1)))
    (drop (i64.atomic.rmw8.and_u (i32.const 4) (i64.const 0x10)))
    (drop (i32.atomic.rmw8.or_u (i32.const 4) (i32.const 3)))
    (drop (i32.atomic.rmw16.xor_u (i32.const 4) (i32.const 0xff00)))
    (drop (i32.atomic.rmw8.xchg_u (i32.const 4) (i32.const 0x1299)))
    (i64.atomic.store16 (i32.const 6) (i64.const 0x9493))
    (i32.atomic.store8 (i32.const 7) (i32.const 0x12ff))
    (i64.atomic.store8 (i32.const 5) (i64.const 0x1200))
    (i32.atomic.store16 (i32.const 8) (i32.const 0xabcd))
    (i32.eq (i32.atomic.rmw8.cmpxchg_u (i32.const 4) (i32.const 0x1233) (i32.const 1))
      (i32.const 0x99))
    (i64.eq (i64.atomic.rmw16.cmpxchg_u (i32.const 6) (i64.const 0x1234ff93)
      (i64.const 0x18492)) (i64.const 0xff93))
    i32.and
    (i32.eq (i32.atomic.load8_u (i32.const 4)) (i32.const 0x99))
    i32.and
    (i32.eq (i32.atomic.load16_u (i32.const 8)) (i32.const 0xabcd))
    i32.and
    (i64.eq (i64.atomic.load32_u (i32.const 4)) (i64.const 0x84920099))
    i32.and
    (i64.eq (i64.atomic.load16_u (i32.const 6)) (i64.const 0x8492))
    i32.and
    (i64.eq (i64.atomic.load8_u (i32.const 7)) (i64.const 0x84))
    i32.and)
  (func (export "unaligned") (result i32)
    (i32.atomic.load offset=1 (i32.const 0)))
  (func (export "outside") (result i32)
    (i32.atomic.load offset=4 (i32.const -4)))
  (func (export "too-wide") (result i32)
    (i32.wrap_i64 (i64.atomic.load (i32.const 65536)))))
(assert_return (invoke "subword") (i32.const 1))
(assert_trap (invoke "unaligned") "unaligned atomic memory access")
(assert_trap (invoke "outside") "out of bounds memory access")
(assert_trap (invoke "too-wide") "out of bounds memory access")

(module
  (memory $first 1)
  (memory $second 1)
  (func (export "indexed") (result i32)
    (i32.atomic.store $second (i32.const 4) (i32.const 42))
    (i32.sub (i32.atomic.load $second (i32.const 4))
      (i32.atomic.load $first (i32.const 4)))))
(assert_return (invoke "indexed") (i32.const 42))

(assert_invalid
  (module (memory 1) (func (result i32) (i32.atomic.load align=2 (i32.const 0))))
  "atomic alignment must be natural")
(assert_invalid
  (module (memory 1) (func (result i32) (i32.atomic.load8_u align=2 (i32.const 0))))
  "atomic alignment must be natural")
(assert_invalid
  (module (memory 1)
    (func (result i32) (i32.atomic.rmw.cmpxchg (i32.const 0) (i64.const 0) (i32.const 7))))
  "type mismatch")
(assert_invalid
  (module (func (result i32) (i32.atomic.load (i32.const 0))))
  "unknown memory")
(assert_malformed
  (module binary "\00asm\01\00\00\00\01\04\01\60\00\00\03\02\01\00"
    "\0a\07\01\05\00\fe\03\01\0b")
  "invalid atomic.fence immediate")
