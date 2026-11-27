;; Validate each synchronous key type with the value types the ABI supports,
;; including a nested map and a reference to a published record.
(component definition
  (type (map bool u8))
  (type (map u8 u8))
  (type (map s8 u8))
  (type (map u16 u8))
  (type (map s16 u8))
  (type (map u32 u8))
  (type (map s32 u8))
  (type (map u64 u8))
  (type (map s64 u8))
  (type (map char u8))
  (type (map string (map u32 (option string))))
  (type (option (map bool (result u32 (error string)))))
  (type (list (map u8 (tuple u32 u64))))
  (type $record (record (field "id" u32)))
  (import "entry" (type $entry (eq $record)))
  (import "read" (func (param "entries" (map string $entry)))))

(assert_invalid
  (component
    (type $record (record (field "id" u32)))
    (import "read" (func (param "entries" (map string $record)))))
  "named component field type is not externally visible")

;; The map and the ordinary list have identical memory layouts and separate
;; type identities at a component boundary.
(assert_invalid
  (component
    (import "give" (func $give (param "entries" (map u8 u64))))
    (component $consumer
      (import "give" (func (param "entries" (list (tuple u8 u64))))))
    (instance (instantiate $consumer (with "give" (func $give)))))
  "component instantiation argument type mismatch")

;; Map results inherit the tuple entry alignment, including padding before
;; the u64 value. A malformed descriptor must trap through the same ABI.
(component
  (core module $m
    (memory (export "mem") 1)
    (data (i32.const 0) "\01\00\00\00\01\00\00\00")
    (data (i32.const 8) "\10\00\00\00\02\00\00\00")
    (data (i32.const 16) "\07\00\00\00\00\00\00\00\01\00\00\00\00\00\00\00"
                        "\07\00\00\00\00\00\00\00\02\00\00\00\00\00\00\00")
    (func (export "good") (result i32) i32.const 8)
    (func (export "bad") (result i32) i32.const 0))
  (core instance $i (instantiate $m))
  (func (export "good") (result (map u8 u64))
    (canon lift (core func $i "good") (memory (core memory $i "mem"))))
  (func (export "bad") (result (map u8 u64))
    (canon lift (core func $i "bad") (memory (core memory $i "mem")))))
(assert_return (invoke "good")
  (map.const (entry (u8.const 7) (u64.const 1)) (entry (u8.const 7) (u64.const 2))))
(assert_trap (invoke "bad") "unaligned canonical list pointer")
