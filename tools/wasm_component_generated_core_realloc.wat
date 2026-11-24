(component
  (import "allocate" (func $allocate (param "ptr" u32) (param "old-size" u32)
    (param "alignment" u32) (param "new-size" u32) (result u32)))
  (import "text" (func $text (result string)))
  (core func $allocate (canon lower (func $allocate)))
  (core module $memory
    (memory (export "memory") 1)
    (func (export "len") (param i32 i32) (result i32) local.get 1))
  (core instance $mem (instantiate $memory))
  (func (export "trap-in-lift") (param "text" string) (result u32)
    (canon lift (core func $mem "len") (memory (core memory $mem "memory"))
      (realloc (core func $allocate))))
  (core func $text (canon lower (func $text) (memory (core memory $mem "memory"))
    (realloc (core func $allocate))))
  (core module $caller
    (import "" "text" (func $text (param i32)))
    (func (export "run") (call $text (i32.const 0))))
  (core instance $caller (instantiate $caller
    (with "" (instance (export "text" (func $text))))))
  (func (export "trap-in-lower") (canon lift (core func $caller "run"))))
