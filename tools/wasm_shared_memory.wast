(module
  (type $entry (shared (func (result i32))))
  (memory (export "memory") 1 2 shared)
  (func (export "crosses") (type $entry)
    (drop (memory.grow (i32.const 1)))
    (i32.store (i32.const 65535) (i32.const 42))
    (memory.copy (i32.const 65534) (i32.const 65535) (i32.const 4))
    (memory.fill (i32.const 65535) (i32.const 1) (i32.const 1))
    (i32.sub (i32.load (i32.const 65534)) (i32.const 256)))
  (func (export "limit") (type $entry) (memory.grow (i32.const 1))))
(assert_return (invoke "crosses") (i32.const 42))
(assert_return (invoke "limit") (i32.const -1))
(register "shared-memory")

(module
  (type $entry (shared (func (result i32))))
  (import "shared-memory" "memory" (memory 2 2 shared))
  (func (export "read-import") (type $entry)
    (i32.add (memory.size) (i32.load (i32.const 65534)))))
(assert_return (invoke "read-import") (i32.const 300))

(assert_unlinkable
  (module (import "shared-memory" "memory" (memory 1 2)))
  "incompatible import type")

(assert_invalid (module (memory 1 shared)) "shared memory must have maximum size")
(assert_invalid (module (memory 2 1 shared)) "size minimum must not be greater than maximum")
(assert_invalid (module (memory 0 65537 shared)) "memory size must be at most 65536 pages")
