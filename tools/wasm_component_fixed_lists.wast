;; Type declarations at the spec size limit are validated without
;; allocating their data. The largest map key/value pair here is itself
;; larger than the limit, but the declared map value is a pointer pair.
(component definition
  (type $bytes (list u8 268435455))
  (type (list u64 33554431))
  (type (list string 16777215))
  (type (list (list u8 134217727) 2))
  (type (record (field "high" (list u8 268435454)) (field "last" u8)))
  (type (map u16 $bytes))
  (type (option (map u16 $bytes))))

(assert_invalid
  (component (type (list u8 0)))
  "fixed-length list must have at least one element")

(assert_invalid
  (component
    (import "take" (func $take (param "value" (list u32 2))))
    (component $child (import "take" (func (param "value" (list u32 3)))))
    (instance (instantiate $child (with "take" (func $take)))))
  "component instantiation argument type mismatch")

(assert_invalid
  (component
    (import "take" (func $take (param "value" (list u32 2))))
    (component $child (import "take" (func (param "value" (tuple u32 u32)))))
    (instance (instantiate $child (with "take" (func $take)))))
  "component instantiation argument type mismatch")

(assert_invalid
  (component
    (type (record (field "many" (list u8 268435440)) (field "text" string))))
  "exceeds maximum byte size")

(assert_invalid
  (component
    (type $r (resource (rep i32)))
    (type (func (result (list (borrow $r) 2)))))
  "component function result contains a borrowed resource")

(assert_invalid
  (component
    (type $r (resource (rep i32)))
    (type (map u32 (list (own $r) 2))))
  "map value type cannot contain a handle")

(component
  (core module $m
    (memory (export "mem") 1)
    (func (export "unaligned") (result i32) i32.const 3))
  (core instance $i (instantiate $m))
  (func (export "unaligned") (result (list u32 2))
    (canon lift (core func $i "unaligned") (memory (core memory $i "mem")))))
(assert_trap (invoke "unaligned") "unaligned canonical fixed-length list result")

(component
  (core module $m
    (memory (export "mem") 1)
    (func (export "too-long") (result i32) i32.const 0))
  (core instance $i (instantiate $m))
  (func (export "too-long") (result (list u8 4097))
    (canon lift (core func $i "too-long") (memory (core memory $i "mem")))))
(assert_trap (invoke "too-long") "canonical list transfer exceeds profile limit")

;; A canonically lowered import receives the inline elements and writes
;; the fixed-list result inline at its caller's result address.
(component
  (component $provider
    (core module $m
      (memory (export "mem") 1)
      (func (export "reverse") (param i32 i32) (result i32)
        i32.const 16
        local.get 1
        i32.store
        i32.const 16
        local.get 0
        i32.store offset=4
        i32.const 16))
    (core instance $i (instantiate $m))
    (func (export "reverse") (param "value" (list u32 2)) (result (list u32 2))
      (canon lift (core func $i "reverse") (memory (core memory $i "mem")))))
  (instance $p (instantiate $provider))
  (core module $memory (memory (export "mem") 1))
  (core instance $memory (instantiate $memory))
  (core func $reverse (canon lower (func $p "reverse") (memory (core memory $memory "mem"))))
  (core module $m
    (import "env" "reverse" (func $reverse (param i32 i32 i32)))
    (import "env" "mem" (memory 1))
    (func (export "run") (result i32)
      i32.const 19
      i32.const 23
      i32.const 32
      call $reverse
      i32.const 32
      i32.load
      i32.const 2
      i32.mul
      i32.const 32
      i32.load offset=4
      i32.add))
  (core instance $i (instantiate $m
    (with "env" (instance (export "reverse" (func $reverse))
                          (export "mem" (memory $memory "mem"))))))
  (func (export "run") (result u32) (canon lift (core func $i "run"))))
(assert_return (invoke "run") (u32.const 65))
